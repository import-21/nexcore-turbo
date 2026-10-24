import os
def after_warmup():
    with open("/tmp/turbo-hook-ran", "w") as fh:
        fh.write(str(os.getpid()))
