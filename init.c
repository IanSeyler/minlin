#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/sysinfo.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>

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
			fprintf(stderr, "/proc/cmdline: %.*s", (int)n, cmdline);
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
		reboot(RB_POWER_OFF);
	}
	fprintf(stderr, "Mounted /dev/vda as ext4 on /mnt\n");

	const char *msg = "hello from init\n";
	int fd = open("/mnt/hello.txt", O_CREAT | O_WRONLY | O_TRUNC, 0644);
	if (fd < 0) {
		perror("open /mnt/hello.txt");
	} else {
		write(fd, msg, strlen(msg));
		close(fd);
		fprintf(stderr, "Wrote: %s", msg);
	}

	char buffer[64] = {0};
	fd = open("/mnt/hello.txt", O_RDONLY);
	if (fd >= 0) {
		ssize_t n = read(fd, buffer, sizeof(buffer) - 1);
		close(fd);
		fprintf(stderr, "Read %zd bytes: %s", n, buffer);
	}

	umount("/mnt");

	int sock = socket(AF_INET, SOCK_DGRAM, 0);
	if (sock < 0) {
		perror("socket");
	} else {
		struct ifreq ifr;
		memset(&ifr, 0, sizeof(ifr));
		strncpy(ifr.ifr_name, "eth0", IFNAMSIZ - 1);

		struct sockaddr_in *addr = (struct sockaddr_in *)&ifr.ifr_addr;
		addr->sin_family = AF_INET;
		inet_pton(AF_INET, "192.168.1.2", &addr->sin_addr);
		if (ioctl(sock, SIOCSIFADDR, &ifr) < 0) {
			perror("ioctl SIOCSIFADDR");
		}

		if (ioctl(sock, SIOCGIFFLAGS, &ifr) < 0) {
			perror("ioctl SIOCGIFFLAGS");
		} else {
			ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
			if (ioctl(sock, SIOCSIFFLAGS, &ifr) < 0) {
				perror("ioctl SIOCSIFFLAGS");
			} else {
				fprintf(stderr, "eth0 up with 192.168.1.2\n");
			}
		}
		close(sock);
	}

	reboot(RB_POWER_OFF);
	return 0;
}
