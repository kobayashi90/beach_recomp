import gdb
gdb.execute("set pagination off")
gdb.execute("set confirm off")
target = int(open("/tmp/mg-target-lwp").read().strip())
picked = None
for th in gdb.selected_inferior().threads():
    try:
        if th.ptid[1] == target:
            picked = th
            break
    except Exception:
        pass
if picked is None:
    print("THREAD NOT FOUND")
else:
    picked.switch()
    gdb.execute("bt")
