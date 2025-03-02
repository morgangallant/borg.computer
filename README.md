Resistance is futile

### cgroup delegation

By default, non-root users (or even root users) can only delegate a subset of the available cgroup controllers. You can see which controllers are available to your user by running the following command:

```bash
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers
```

If you want to expand the available controllers, you can run the following:

```bash
sudo mkdir -p /etc/systemd/system/user@.service.d
cat <<EOF | sudo tee /etc/systemd/system/user@.service.d/delegate.conf
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload
```
