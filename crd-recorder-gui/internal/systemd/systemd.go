// Package systemd is a thin wrapper over systemctl for a single unit.
package systemd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const systemctl = "/usr/bin/systemctl"

// Show returns the requested properties of unit (`systemctl show -p ...`).
func Show(unit string, props ...string) (map[string]string, error) {
	args := []string{"show", unit, "--no-pager"}
	for _, p := range props {
		args = append(args, "-p", p)
	}
	out, err := exec.Command(systemctl, args...).Output()
	if err != nil {
		return nil, fmt.Errorf("systemctl show %s: %w", unit, err)
	}
	return parseShow(string(out)), nil
}

func parseShow(out string) map[string]string {
	m := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		if k, v, ok := strings.Cut(line, "="); ok {
			m[k] = v
		}
	}
	return m
}

// Enable runs `systemctl enable --now unit`; Disable runs `disable --now`.
// Both go through `sudo -n`: provisioning installs a sudoers rule allowing
// exactly these two commands, and -n makes sudo fail instead of prompting when
// the rule is missing.
func Enable(unit string) error  { return privileged("enable", "--now", unit) }
func Disable(unit string) error { return privileged("disable", "--now", unit) }

func privileged(args ...string) error {
	out, err := exec.Command("sudo", append([]string{"-n", systemctl}, args...)...).CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if strings.Contains(msg, "password is required") {
			msg = "not allowed: the sudoers rule for crd-recorder is missing (re-run the Ansible `recorder` tag)"
		}
		return fmt.Errorf("systemctl %s: %s", strings.Join(args, " "), msg)
	}
	return nil
}

// CgroupPIDs lists the processes in a unit's control group, given its
// ControlGroup property (e.g. /system.slice/crd-recorder.service).
func CgroupPIDs(cgroup string) ([]int, error) {
	if cgroup == "" {
		return nil, nil
	}
	b, err := os.ReadFile(filepath.Join("/sys/fs/cgroup", cgroup, "cgroup.procs"))
	if err != nil {
		return nil, err
	}
	var pids []int
	for _, f := range strings.Fields(string(b)) {
		if pid, err := strconv.Atoi(f); err == nil {
			pids = append(pids, pid)
		}
	}
	return pids, nil
}
