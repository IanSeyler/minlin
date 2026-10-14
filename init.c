#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
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

int main(int argc, char **argv) {
	fprintf(stderr, "Hello from init.c!\n");
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

	fprintf(stderr, "init argv:");
	for (int i = 0; i < argc; i++) {
		fprintf(stderr, " %s", argv[i]);
	}
	fprintf(stderr, "\n");

	mkdir("/proc", 0755);
	if (mount("proc", "/proc", "proc", 0, NULL) < 0) {
		perror("mount /proc");
	} else {
		int fd = open("/proc/cmdline", O_RDONLY);
		if (fd >= 0) {
			char cmdline[256] = {0};
			ssize_t n = read(fd, cmdline, sizeof(cmdline) - 1);
			close(fd);
			fprintf(stderr, "/proc/cmdline: %.*s", (int)(n > 0 ? n : 0), cmdline);
		} else {
			perror("open /proc/cmdline");
		}
		umount("/proc");
	}

	struct sysinfo info;
	if (sysinfo(&info) < 0) {
		perror("sysinfo");
	} else {
		fprintf(stderr, "Free memory: %lu KB\n",
			(unsigned long)(info.freeram * info.mem_unit) / 1024);
	}

	mkdir("/mnt", 0755);
	if (mount("/dev/vda", "/mnt", "ext4", 0, NULL) < 0) {
		perror("mount /dev/vda");
		reboot(RB_AUTOBOOT);
	}
	fprintf(stderr, "Mounted /dev/vda as ext4 on /mnt\n");

	const char *msg = "hello from init\n";
	int fd = open("/mnt/hello.txt", O_CREAT | O_WRONLY | O_TRUNC, 0644);
	if (fd < 0) {
		perror("open /mnt/hello.txt");
	} else {
		if (write(fd, msg, strlen(msg)) < 0)
			perror("write /mnt/hello.txt");
		else
			fprintf(stderr, "Wrote: %s", msg);
		close(fd);
	}

	char buffer[64] = {0};
	fd = open("/mnt/hello.txt", O_RDONLY);
	if (fd >= 0) {
		ssize_t n = read(fd, buffer, sizeof(buffer) - 1);
		close(fd);
		fprintf(stderr, "Read %zd bytes: %s", n, buffer);
	}

	umount("/mnt");

	setup_network();

	/* No ACPI power-off in a microVM; the VMM exits on reboot instead. */
	reboot(RB_AUTOBOOT);
	return 0;
}
