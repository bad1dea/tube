FROM docker.io/library/alpine:3.22
RUN apk add --no-cache openssh bash zsh vim nano tmux htop less python3 \
 && adduser -D -s /bin/bash tester \
 && echo 'tester:tester-pass' | chpasswd \
 && mkdir -p /home/tester/.ssh && chmod 700 /home/tester/.ssh && chown tester:tester /home/tester/.ssh
COPY sshd_config /etc/ssh/sshd_config
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
