# PROTOTYPE for #33, throwaway. Drive Go age's passphrase prompt through a pseudo-terminal, since
# age reads a passphrase only from a terminal. Usage: python3 goage.py PASSPHRASE age ARGS...
import os, pty, sys

passphrase, argv = sys.argv[1].encode(), sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
seen = b""
answered = 0
while True:
    try:
        data = os.read(fd, 1024)
    except OSError:
        break
    if not data:
        break
    seen += data
    if seen.count(b"assphrase") > answered:
        os.write(fd, passphrase + b"\n")
        answered += 1
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
