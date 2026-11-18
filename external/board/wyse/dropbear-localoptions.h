/* Added to dropbear's localoptions.h. Only key logins (root's keys). */
#define DROPBEAR_SVR_PASSWORD_AUTH 0
/* Nothing the image lacks: no sftp-server. No pid file
 * (nothing reads it; fopen("") fails, so none is written). No agent
 * forwarding (ssh -A). */
#define DROPBEAR_SFTPSERVER 0
#define DROPBEAR_PIDFILE ""
#define DROPBEAR_SVR_AGENTFWD 0
/* The login banner (/etc/motd, written by post-build.sh). */
#define DO_MOTD 1
