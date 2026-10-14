#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/sysinfo.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static int set_addr(int sock, const char *dev, unsigned long req,
		    const char *addr, const char *what) {
	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, dev, IFNAMSIZ - 1);

	struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
	sin->sin_family = AF_INET;
	if (inet_pton(AF_INET, addr, &sin->sin_addr) != 1) {
		fprintf(stderr, "%s: invalid address %s\n", what, addr);
		return -1;
	}
	if (ioctl(sock, req, &ifr) < 0) {
		perror(what);
		return -1;
	}
	return 0;
}

static int add_default_route(int sock, const char *dev, const char *gw) {
	struct rtentry rt;
	memset(&rt, 0, sizeof(rt));
	((struct sockaddr_in *)&rt.rt_dst)->sin_family = AF_INET;
	((struct sockaddr_in *)&rt.rt_genmask)->sin_family = AF_INET;

	struct sockaddr_in *sin = (struct sockaddr_in *)&rt.rt_gateway;
	sin->sin_family = AF_INET;
	if (inet_pton(AF_INET, gw, &sin->sin_addr) != 1) {
		fprintf(stderr, "invalid gateway %s\n", gw);
		return -1;
	}
	rt.rt_flags = RTF_UP | RTF_GATEWAY;
	rt.rt_dev = (char *)dev;
	if (ioctl(sock, SIOCADDRT, &rt) < 0) {
		perror("ioctl SIOCADDRT");
		return -1;
	}
	return 0;
}

/*
 * Configure networking from the kernel's ip= parameter, in the same format
 * the kernel's own IP autoconfig uses:
 *   ip=<client-ip>:<server-ip>:<gw-ip>:<netmask>:<hostname>:<device>:<autoconf>
 * CONFIG_IP_PNP is off, so the kernel hands ip= to init as an env variable.
 */
static void setup_network(void) {
	const char *ip = getenv("ip");
	if (!ip) {
		fprintf(stderr, "No ip= on kernel command line, skipping network\n");
		return;
	}

	char buf[256];
	char *field[7] = {0};
	char *p = buf;
	strncpy(buf, ip, sizeof(buf) - 1);
	buf[sizeof(buf) - 1] = '\0';
	for (int i = 0; i < 7 && p; i++) {
		char *f = strsep(&p, ":");
		field[i] = *f ? f : NULL;
	}
	const char *client = field[0], *gw = field[2], *mask = field[3];
	const char *dev = field[5] ? field[5] : "eth0";

	if (!client) {
		fprintf(stderr, "No client address in ip=%s\n", ip);
		return;
	}

	int sock = socket(AF_INET, SOCK_DGRAM, 0);
	if (sock < 0) {
		perror("socket");
		return;
	}

	if (set_addr(sock, dev, SIOCSIFADDR, client, "ioctl SIOCSIFADDR") < 0)
		goto out;
	if (mask && set_addr(sock, dev, SIOCSIFNETMASK, mask, "ioctl SIOCSIFNETMASK") < 0)
		goto out;

	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, dev, IFNAMSIZ - 1);
	if (ioctl(sock, SIOCGIFFLAGS, &ifr) < 0) {
		perror("ioctl SIOCGIFFLAGS");
		goto out;
	}
	ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
	if (ioctl(sock, SIOCSIFFLAGS, &ifr) < 0) {
		perror("ioctl SIOCSIFFLAGS");
		goto out;
	}
	fprintf(stderr, "%s up with %s netmask %s\n", dev, client,
		mask ? mask : "(classful default)");

	if (gw && add_default_route(sock, dev, gw) == 0)
		fprintf(stderr, "default route via %s\n", gw);
out:
	close(sock);
}


#define ROOT_DEV	"/dev/vda"
#define ROOT_FSTYPE	"ext4"
#define INIT_CONF	"/etc/init.conf"
#define MAX_SERVICES	16
#define MAX_ARGS	32

/*
 * Mount the disk and make it the root filesystem, the same way switch_root
 * does: move the mount over the initramfs's / and chroot into it. Then give
 * the new root the pseudo-filesystems programs expect to find.
 */
static int mount_root(void) {
	mkdir("/mnt", 0755);
	if (mount(ROOT_DEV, "/mnt", ROOT_FSTYPE, 0, NULL) < 0) {
		perror("mount " ROOT_DEV);
		return -1;
	}
	if (chdir("/mnt") < 0 || mount(".", "/", NULL, MS_MOVE, NULL) < 0 ||
	    chroot(".") < 0 || chdir("/") < 0) {
		perror("switch to " ROOT_DEV);
		return -1;
	}
	fprintf(stderr, "Mounted %s (%s) as /\n", ROOT_DEV, ROOT_FSTYPE);

	mkdir("/dev", 0755);
	if (mount("devtmpfs", "/dev", "devtmpfs", 0, NULL) < 0)
		perror("mount /dev");
	mkdir("/proc", 0755);
	if (mount("proc", "/proc", "proc", 0, NULL) < 0)
		perror("mount /proc");
	/* devtmpfs leaves these to userspace (udev normally creates them). */
	static const char *const links[][2] = {
		{ "/proc/self/fd", "/dev/fd" },
		{ "/proc/self/fd/0", "/dev/stdin" },
		{ "/proc/self/fd/1", "/dev/stdout" },
		{ "/proc/self/fd/2", "/dev/stderr" },
	};
	for (size_t i = 0; i < sizeof(links) / sizeof(links[0]); i++)
		if (symlink(links[i][0], links[i][1]) < 0 && errno != EEXIST)
			perror(links[i][1]);
	/* Without CONFIG_SHMEM, tmpfs is backed by ramfs. */
	mkdir("/tmp", 01777);
	if (mount("tmpfs", "/tmp", "tmpfs", 0, NULL) < 0)
		perror("mount /tmp");
	return 0;
}

enum action { ACT_WAIT, ACT_ONCE, ACT_RESPAWN };

struct service {
	enum action action;
	char *argv[MAX_ARGS + 1];
	pid_t pid;
};

static struct service services[MAX_SERVICES];
static int nservices;

/*
 * Read INIT_CONF. Each non-blank line that does not start with '#' is
 *   <action> <path> [args...]
 * where action is one of
 *   wait     run it and wait for it to exit before reading on (setup steps)
 *   once     start it and leave it running
 *   respawn  start it, and start it again whenever it exits
 * Arguments are split on whitespace; there is no quoting.
 */
static int read_conf(void) {
	FILE *f = fopen(INIT_CONF, "r");
	if (!f) {
		perror("open " INIT_CONF);
		return -1;
	}

	char line[512];
	int lineno = 0;
	while (fgets(line, sizeof(line), f)) {
		lineno++;
		char *p = line, *tok;
		int argc = 0;
		struct service *svc = &services[nservices];

		while ((tok = strsep(&p, " \t\r\n"))) {
			if (!*tok)
				continue;
			if (argc == 0 && tok[0] == '#')
				break;
			if (argc == MAX_ARGS) {
				fprintf(stderr, INIT_CONF ":%d: too many arguments\n", lineno);
				break;
			}
			svc->argv[argc++] = strdup(tok);
		}
		if (argc == 0)
			continue;
		svc->argv[argc] = NULL;

		const char *act = svc->argv[0];
		if (!strcmp(act, "wait"))
			svc->action = ACT_WAIT;
		else if (!strcmp(act, "once"))
			svc->action = ACT_ONCE;
		else if (!strcmp(act, "respawn"))
			svc->action = ACT_RESPAWN;
		else {
			fprintf(stderr, INIT_CONF ":%d: unknown action '%s'\n", lineno, act);
			continue;
		}
		if (argc < 2) {
			fprintf(stderr, INIT_CONF ":%d: no command given\n", lineno);
			continue;
		}
		memmove(svc->argv, svc->argv + 1, argc * sizeof(svc->argv[0]));

		if (++nservices == MAX_SERVICES) {
			fprintf(stderr, INIT_CONF ": only %d entries supported\n", MAX_SERVICES);
			break;
		}
	}
	fclose(f);
	return 0;
}

static void spawn(struct service *svc) {
	pid_t pid = fork();
	if (pid < 0) {
		perror("fork");
		return;
	}
	if (pid == 0) {
		setsid();
		execv(svc->argv[0], svc->argv);
		fprintf(stderr, "init: exec %s: %s\n", svc->argv[0], strerror(errno));
		_exit(127);
	}
	svc->pid = pid;
	fprintf(stderr, "init: started %s (pid %d)\n", svc->argv[0], pid);
}

/*
 * Reap children until target exits (or, with target -1, until there are no
 * children left). As PID 1 this also collects orphans that were reparented
 * to us, and restarts respawn services as they exit.
 */
static void wait_for(pid_t target) {
	for (;;) {
		int status;
		pid_t pid = wait(&status);
		if (pid < 0) {
			if (errno == EINTR)
				continue;
			return;
		}

		struct service *svc = NULL;
		for (int i = 0; i < nservices; i++)
			if (services[i].pid == pid)
				svc = &services[i];
		if (svc) {
			svc->pid = 0;
			if (WIFSIGNALED(status))
				fprintf(stderr, "init: %s (pid %d) killed by signal %d\n",
					svc->argv[0], pid, WTERMSIG(status));
			else
				fprintf(stderr, "init: %s (pid %d) exited with status %d\n",
					svc->argv[0], pid, WEXITSTATUS(status));
			if (svc->action == ACT_RESPAWN) {
				sleep(1);	/* don't spin on a service that dies at once */
				spawn(svc);
			}
		}
		if (pid == target)
			return;
	}
}

int main(void) {
	fprintf(stderr, "Hello from init.c!\n");
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

	struct sysinfo info;
	if (sysinfo(&info) == 0)
		fprintf(stderr, "Free memory: %lu KB\n",
			(unsigned long)(info.freeram * info.mem_unit) / 1024);

	setup_network();

	if (mount_root() == 0 && read_conf() == 0) {
		setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
		setenv("HOME", "/", 1);

		for (int i = 0; i < nservices; i++) {
			spawn(&services[i]);
			if (services[i].action == ACT_WAIT && services[i].pid)
				wait_for(services[i].pid);
		}
		wait_for(-1);
		fprintf(stderr, "init: no processes left\n");
	}

	sync();
	mount(NULL, "/", NULL, MS_REMOUNT | MS_RDONLY, NULL);
	/* No ACPI power-off in a microVM; the VMM exits on reboot instead. */
	reboot(RB_AUTOBOOT);
	return 0;
}
