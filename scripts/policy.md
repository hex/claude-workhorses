Use a workhorse to keep this machine free when an unattended job takes over 5 minutes,
the 1-minute load exceeds the local core count, or the job writes over 5 GB. Stay local
for jobs under 2 minutes or those needing more RAM than the hosts have, a GPU or code signing.
Match the required OS, architecture and tools. Respect the user's notes below.

For git repos, run `wh [host[,host...]] --timeout <limit> -- <command...>` in a background shell
from inside the repo. Use `@WH@` if wh is off PATH. Without a host, wh picks an available
one by load and cached copy. With more than one host, wh picks the least busy of those.
`@MIRROR@ run` locks and patches the shared work copy, including
.git. Install dependencies there; never copy builds across architectures. Exit 124 means
timeout and 3 with BLOCKED means the job did not run. Exit 2 is bad usage or hosts file only
when wh says so on stderr; else the command itself exited 2, as make does on a failed build.
Make a first copy over 1 GB on a network that reaches the host without Tailscale.
See the workhorse skill for cache exclusions, host selection and first-run details.

Provision only with `bash @SYNC@`. Recipes in `@CONFIG@/tools` accept @arch, @os and
@hosts filters. If the job needs a missing or newer tool, use the question tool to show
the exact tools line or full recipe before syncing. Recommend adding it, syncing the
target hosts, checking sync.sh diff and offloading. Run locally only if declined; say so.

Outside git, use a suitable host with load below its core count that answers
`ssh -o BatchMode=yes -o ConnectTimeout=5 <ssh> uptime`. If none qualifies, run locally
and say so. Lock ~/work/<repo>-<first 8 hex digits of SHA1 of the local absolute path>.lock
with mkdir before rsync -az --delete to the corresponding work directory. Record this
machine, time and job in the lock's owner file, and the detached job's pid on the host in its pid
file. An existing lock belongs to another run unless stale: its pid file names a dead
process. Remove a stale lock with rm -r and say so. One with no pid file over an hour old may
be a run still copying: report it with its rm -r command, and run that only once the user
says its run has ended.
Use wh's exclusions. Run detached with a time limit, write run.log and the exit code in
run.status, and wait in the background. Release your lock at the end.

Bring back only logs and reports. Edit locally. Keep shared git copies and dependencies.
Remove only this session's non-git copy. Before deleting files a job could use, check
~/work/*.lock and their owner files; wait for other sessions' locks that are not stale to clear. Ask before
sudo or installing outside the remote directory.
