// SPDX-License-Identifier: GPL-2.0
/*
 * security/selinux/susfs_apatch.c - APatch glue for SUSFS
 *
 * susfs4ksu (https://gitlab.com/simonpunk/susfs4ksu) is written against the
 * KernelSU in-kernel driver.  A kernel built for APatch has no KernelSU source
 * at all - APatch's kernel side is the prebuilt KernelPatch blob that gets
 * injected into the boot image - so SUSFS is left without the four things it
 * expects from its host:
 *
 *  1. susfs_is_current_ksu_domain() / susfs_is_current_zygote_domain()
 *     fs/susfs.c and fs/namespace.c use these to tell "a mount that root made"
 *     from "a mount the system made".  Here they are answered from the SELinux
 *     SID of the current process: APatch's su shell and apd (which does all
 *     the module mounts) run in MAGISK_SCTX, see MAGISK_SCTX in
 *     kernel/patch/android/userd.c of KernelPatch.
 *
 *  2. setup_selinux() and ksu_cred
 *     fs/susfs.c overrides the credentials with ksu_cred while it resolves
 *     paths for sus_path_loop / sus_kstat, and setup_selinux() is how it gives
 *     its sdcard monitor thread the root context.
 *
 *  3. the reboot(2) command channel (CMD_SUSFS_*)
 *     KernelSU receives the CMD_SUSFS_* commands from a kprobe on reboot(2)
 *     with magic1 == KSU_INSTALL_MAGIC1 and magic2 == SUSFS_MAGIC.  APatch
 *     hijacks syscall 45 instead and never touches reboot(2), so the same
 *     protocol can simply be handled at the top of SYSCALL_DEFINE4(reboot) -
 *     which also means the stock ksu_susfs userspace tool works unmodified.
 *
 *  4. the TIF_PROC_* thread flags
 *     KernelSU sets them from its setresuid hook when zygote drops a freshly
 *     forked child to its app uid.  APatch has no such hook, so they are
 *     derived from the uid in commit_creds(), which is the path APatch's own
 *     commit_su() uses as well - so the flags stay correct when a process
 *     gains or loses root.
 *
 * Copyright (C) 2025 susfs4ksu and the pox-kernel-begonia contributors
 */

#include <linux/capability.h>
#include <linux/cred.h>
#include <linux/export.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/printk.h>
#include <linux/sched.h>
#include <linux/securebits.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/thread_info.h>
#include <linux/uaccess.h>
#include <linux/uidgid.h>

#include "objsec.h"
#include "security.h"

#include <linux/susfs.h>
#include <linux/susfs_def.h>

#define SUSFS_APATCH_TAG		"susfs-apatch: "
#define SUSFS_APATCH_LOGI(fmt, ...)	pr_info(SUSFS_APATCH_TAG fmt, ##__VA_ARGS__)
#define SUSFS_APATCH_LOGE(fmt, ...)	pr_err(SUSFS_APATCH_TAG fmt, ##__VA_ARGS__)
#define SUSFS_APATCH_LOGD(fmt, ...)	pr_debug(SUSFS_APATCH_TAG fmt, ##__VA_ARGS__)

#define SUSFS_APATCH_MAX_SU_DOMAINS	4

/*
 * Privileged credential handed to fs/susfs.c through ksu_cred.  It is built on
 * first use so that the SELinux SID of the APatch root context is known.
 */
struct cred *ksu_cred;
EXPORT_SYMBOL_GPL(ksu_cred);

/* Cached SIDs of the APatch root contexts and of zygote. */
static u32 susfs_apatch_su_sid[SUSFS_APATCH_MAX_SU_DOMAINS];
static char susfs_apatch_su_context[64];
static u32 susfs_apatch_zygote_sid;
static bool susfs_apatch_sids_ready;
static bool susfs_apatch_sid_warned;

static u32 susfs_apatch_sid_of(const char *context)
{
	u32 sid = 0;

	if (!context || !context[0])
		return 0;
	if (security_context_str_to_sid(&selinux_state, context, &sid, GFP_KERNEL))
		return 0;
	return sid;
}

/*
 * Resolve the SIDs lazily: on Android the policy is loaded by init, so at
 * late_initcall time the contexts may still be unknown.  Every caller is in a
 * sleepable path (mount, open, proc read), so retrying here is safe.
 */
static void susfs_apatch_resolve_sids(void)
{
	const char *p = CONFIG_SUSFS_APATCH_SU_DOMAINS;
	int n = 0;

	if (susfs_apatch_sids_ready)
		return;
	if (!selinux_initialized(&selinux_state))
		return;

	while (*p && n < SUSFS_APATCH_MAX_SU_DOMAINS) {
		const char *start;
		char context[64];
		size_t len;
		u32 sid;

		while (*p == ' ' || *p == '\t')
			p++;
		if (!*p)
			break;
		start = p;
		while (*p && *p != ' ' && *p != '\t')
			p++;
		len = p - start;
		if (len >= sizeof(context))
			len = sizeof(context) - 1;
		memcpy(context, start, len);
		context[len] = '\0';

		sid = susfs_apatch_sid_of(context);
		if (sid) {
			susfs_apatch_su_sid[n++] = sid;
			if (!susfs_apatch_su_context[0])
				strlcpy(susfs_apatch_su_context, context,
					sizeof(susfs_apatch_su_context));
		} else
			SUSFS_APATCH_LOGD("context '%s' is unknown to the policy\n", context);
	}

	susfs_apatch_zygote_sid = susfs_apatch_sid_of(CONFIG_SUSFS_APATCH_ZYGOTE_DOMAIN);

	if (n && susfs_apatch_zygote_sid) {
		susfs_apatch_sids_ready = true;
		SUSFS_APATCH_LOGI("root contexts resolved, zygote sid %u\n", susfs_apatch_zygote_sid);
	} else if (!susfs_apatch_sid_warned) {
		susfs_apatch_sid_warned = true;
		SUSFS_APATCH_LOGE("cannot resolve '%s' / '%s', root mounts stay visible;"
				 " check SUSFS_APATCH_SU_DOMAINS\n",
				 CONFIG_SUSFS_APATCH_SU_DOMAINS,
				 CONFIG_SUSFS_APATCH_ZYGOTE_DOMAIN);
	}
}

static bool susfs_apatch_sid_is_su(u32 sid)
{
	int i;

	for (i = 0; i < SUSFS_APATCH_MAX_SU_DOMAINS; i++)
		if (susfs_apatch_su_sid[i] && susfs_apatch_su_sid[i] == sid)
			return true;
	return false;
}


/*
 * Does the current process belong to the root side (APatch's su shell, apd,
 * ...)?  Used by fs/namespace.c to decide which mounts get a mnt_id from the
 * sus range, and by fs/susfs.c for its uid schemes.
 */
bool susfs_is_current_ksu_domain(void)
{
	bool ret = false;

	susfs_apatch_resolve_sids();
	if (susfs_apatch_sids_ready)
		ret = susfs_apatch_sid_is_su(current_sid());

	SUSFS_APATCH_LOGD("ksu_domain: %d (uid %u)\n", ret, current_uid().val);
	return ret;
}

/*
 * Is the current process zygote?  Mounts cloned by zygote get a recycled
 * (small) mnt_id so an app's mount namespace does not reveal that mounts were
 * taken out of it.
 */
bool susfs_is_current_zygote_domain(void)
{
	if (!susfs_apatch_sids_ready) {
		susfs_apatch_resolve_sids();
		if (!susfs_apatch_sids_ready)
			return false;
	}
	return current_sid() == susfs_apatch_zygote_sid;
}

/*
 * Assign the APatch root context to a prepared credential.  Provided for
 * fs/susfs.c, which uses it for its sdcard monitor thread.
 */
void setup_selinux(const char *domain, struct cred *cred)
{
	u32 sid;

	if (!domain || !cred || !cred->security)
		return;
	if (security_context_str_to_sid(&selinux_state, domain, &sid, GFP_KERNEL)) {
		/*
		 * fs/susfs.c asks for KernelSU's "u:r:ksu:s0", which does not
		 * exist on an APatch system.  Give it the APatch root context
		 * instead of leaving the thread with whatever it inherited.
		 */
		if (susfs_apatch_su_context[0] &&
		    !security_context_str_to_sid(&selinux_state,
						 susfs_apatch_su_context, &sid,
						 GFP_KERNEL)) {
			SUSFS_APATCH_LOGD("'%s' unknown, using '%s'\n", domain,
					  susfs_apatch_su_context);
			((struct task_security_struct *)cred->security)->sid = sid;
			return;
		}
		SUSFS_APATCH_LOGD("unknown context '%s'\n", domain);
		return;
	}
	((struct task_security_struct *)cred->security)->sid = sid;
}

static void susfs_apatch_become_root(struct cred *cred)
{
	cred->uid = GLOBAL_ROOT_UID;
	cred->euid = GLOBAL_ROOT_UID;
	cred->suid = GLOBAL_ROOT_UID;
	cred->fsuid = GLOBAL_ROOT_UID;
	cred->gid = GLOBAL_ROOT_GID;
	cred->egid = GLOBAL_ROOT_GID;
	cred->sgid = GLOBAL_ROOT_GID;
	cred->fsgid = GLOBAL_ROOT_GID;
	cred->cap_inheritable = CAP_EMPTY_SET;
	cred->cap_permitted = CAP_FULL_SET;
	cred->cap_effective = CAP_FULL_SET;
	cred->cap_bset = CAP_FULL_SET;
	cred->securebits = SECUREBITS_DEFAULT;
}

/*
 * Build (once) the root credential that fs/susfs.c overrides its own
 * credentials with.  Only uid 0 may trigger the command channel, so this is
 * always a copy of a root credential that gets the APatch root context.
 */
static struct cred *susfs_apatch_get_ksu_cred(void)
{
	const char *context = NULL;
	struct cred *cred;

	if (likely(ksu_cred))
		return ksu_cred;

	susfs_apatch_resolve_sids();
	if (susfs_apatch_su_context[0])
		context = susfs_apatch_su_context;

	cred = prepare_creds();
	if (!cred)
		return NULL;

	if (context)
		setup_selinux(context, cred);
	susfs_apatch_become_root(cred);

	/* prepare_creds() took a reference for us; keep it alive for the
	 * lifetime of the kernel, like KernelSU's ksu_cred. */
	ksu_cred = cred;
	SUSFS_APATCH_LOGI("privileged susfs credential ready\n");
	return ksu_cred;
}

/*
 * reboot(2) command channel.  Identical protocol to KernelSU, so the stock
 * ksu_susfs tool drives this without changes.
 *
 * Returns true when the call was a SUSFS command and must not fall through to
 * the real reboot(2).
 */
int susfs_apatch_handle_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg)
{
	/* Magic check first: this must never interfere with a real reboot. */
	if (magic1 != KSU_INSTALL_MAGIC1 || magic2 != SUSFS_MAGIC)
		return false;

	/* Same policy as KernelSU: configuration is a root only operation. */
	if (current_uid().val != 0) {
		SUSFS_APATCH_LOGE("CMD 0x%x refused for uid %u\n", cmd, current_uid().val);
		return false;
	}

	/* Make sure the privileged credential is around before the first
	 * command that needs it. */
	susfs_apatch_get_ksu_cred();

	SUSFS_APATCH_LOGD("CMD 0x%x\n", cmd);

#ifdef CONFIG_KSU_SUSFS_SUS_PATH
	if (cmd == CMD_SUSFS_ADD_SUS_PATH) {
		susfs_add_sus_path(arg);
		return true;
	}
	if (cmd == CMD_SUSFS_ADD_SUS_PATH_LOOP) {
		susfs_add_sus_path_loop(arg);
		return true;
	}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
	if (cmd == CMD_SUSFS_HIDE_SUS_MNTS_FOR_NON_SU_PROCS) {
		susfs_set_hide_sus_mnts_for_non_su_procs(arg);
		return true;
	}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_KSTAT
	if (cmd == CMD_SUSFS_ADD_SUS_KSTAT) {
		susfs_add_sus_kstat(arg);
		return true;
	}
	if (cmd == CMD_SUSFS_UPDATE_SUS_KSTAT) {
		susfs_update_sus_kstat(arg);
		return true;
	}
	if (cmd == CMD_SUSFS_ADD_SUS_KSTAT_STATICALLY) {
		susfs_add_sus_kstat(arg);
		return true;
	}
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_UNAME
	if (cmd == CMD_SUSFS_SET_UNAME) {
		susfs_set_uname(arg);
		return true;
	}
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
	if (cmd == CMD_SUSFS_ENABLE_LOG) {
		susfs_enable_log(arg);
		return true;
	}
#endif
#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
	if (cmd == CMD_SUSFS_SET_CMDLINE_OR_BOOTCONFIG) {
		susfs_set_cmdline_or_bootconfig(arg);
		return true;
	}
#endif
#ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT
	if (cmd == CMD_SUSFS_ADD_OPEN_REDIRECT) {
		susfs_add_open_redirect(arg);
		return true;
	}
#endif
#ifdef CONFIG_KSU_SUSFS_SUS_MAP
	if (cmd == CMD_SUSFS_ADD_SUS_MAP) {
		susfs_add_sus_map(arg);
		return true;
	}
#endif
#ifdef CONFIG_KSU_SUSFS_ENABLE_AVC_LOG_SPOOFING
	if (cmd == CMD_SUSFS_ENABLE_AVC_LOG_SPOOFING) {
		susfs_set_avc_log_spoofing(arg);
		return true;
	}
#endif
	if (cmd == CMD_SUSFS_SHOW_ENABLED_FEATURES) {
		susfs_get_enabled_features(arg);
		return true;
	}
	if (cmd == CMD_SUSFS_SHOW_VARIANT) {
		susfs_show_variant(arg);
		return true;
	}
	if (cmd == CMD_SUSFS_SHOW_VERSION) {
		susfs_show_version(arg);
		return true;
	}

	SUSFS_APATCH_LOGE("unknown SUSFS command 0x%x\n", cmd);
	return true;
}

/*
 * Maintain the TIF_PROC_* flags that gate sus_map, open_redirect, sus_kstat
 * and the mount hiding.
 *
 * This runs from commit_creds(), which covers every credential change we care
 * about: zygote dropping a child to its app uid, APatch's su granting root to
 * a process (KernelPatch's commit_common_su()/commit_kernel_su() both build a
 * cred and call commit_creds()), and ordinary setuid()/setresuid().
 */
void susfs_apatch_update_proc_flags(const struct cred *new)
{
	uid_t uid = from_kuid(&init_user_ns, new->uid);
	uid_t euid = from_kuid(&init_user_ns, new->euid);

	if (euid)
		uid = euid;

	if (uid == 0) {
		/* root (su) sees everything again */
		clear_thread_flag(TIF_PROC_NO_SU);
		clear_thread_flag(TIF_PROC_UMOUNTED);
		return;
	}

	/* An ordinary Android app: everything root did stays hidden from it. */
	if (uid % 100000 >= (uid_t)CONFIG_SUSFS_APATCH_HIDE_UID_MIN) {
		set_thread_flag(TIF_PROC_NO_SU);
		set_thread_flag(TIF_PROC_UMOUNTED);
		return;
	}

	clear_thread_flag(TIF_PROC_NO_SU);
	clear_thread_flag(TIF_PROC_UMOUNTED);
}

static int __init susfs_apatch_init(void)
{
	susfs_init();
	/*
	 * Resolve the SIDs eagerly when the policy happens to be loaded
	 * already; otherwise the first mount/open resolves them.
	 */
	susfs_apatch_resolve_sids();
	return 0;
}
late_initcall(susfs_apatch_init);