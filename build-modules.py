#!/usr/bin/env python2.7
import urllib2, json, re
import os, subprocess, shlex

IS_RASPI_RE = r'arm(v[6-7](l|hf))$'
CROSS_COMPILE_ARGS = "ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-"
CROSS_COMPILE_PATH = os.path.expanduser("~") + "/src/raspberrypi"\
        "/tools/arm-bcm2708/gcc-linaro-arm-linux-gnueabihf-raspbian-x64/bin/"

class GitHubRepo:
    def __init__(self, user, project):
        self.GITHUB_API_URL = 'https://api.github.com/repos'
        self.user = user;
        self.project = project;

    def __iter__(self):
        self.n = 0
        return self

    def next(self):
        ret = self.log(max_count=1, revision="HEAD~{}".format(self.n))
        if ret is not None:
            self.n += 1
            return ret[0]
        else:
            raise StopIteration

    def log(self, max_count=10, revision="HEAD"):
        try:
            json_str = urllib2.urlopen("{}/{}/{}/commits?per_page={}&sha={}"
                    .format(self.GITHUB_API_URL, self.user, self.project,
                            max_count, revision)).read()
            commits = json.loads(json_str)
        except urllib2.HTTPError as e:
            print e
            return

        messages = []
        for c in commits:
            messages.append(
                    (c['sha'][0:8], c['commit']['message'].split('\n')[0]))
        return messages

def query_yes_no(question):
    yes = {'yes','y',''}
    no = {'no','n'}

    print "{} [Y/n]".format(question),
    while True:
        choice = raw_input().lower()
        if choice in yes:
           return True
        elif choice in no:
           return False
        else:
           print "Please respond with 'yes' or 'no'"

def main(cross_compile_args=""):
    hexxeh = GitHubRepo("Hexxeh", "rpi-firmware")
    taudac = GitHubRepo("taudac", "modules")
    git_cmd = "git -C ../modules/ "

    # get latest supported kernel version
    ckver = re.match(r'taudac-.* for ([\d\.]+)', taudac.log(1)[0][1]).group(1)
    print "Latest supported kernel is {}".format(ckver)

    # check if newer kernels are available
    pending = []
    for c in hexxeh:
        m = re.match(r'kernel: Bump to ([\d\.]+)', c[1])
        if m is not None:
            nkver = m.group(1)
            if nkver == ckver:
                break
            else:
                print "New kernel available: {}".format(nkver)
                pending.append((c[0], nkver))

    if not pending:
        print "Up-to-date with latest 'Hexxeh' kernel"
        return

    # download sources and build modules for each new kernel
    for sha, kver in pending:
        # download
        subprocess.check_call(["./get-rpi-kernel-sources.sh", sha])
        # remove old modules
        subprocess.check_call("rm -r ../modules/lib", shell=True)
        # launch make
        for pver in ["", "-v7"]:
            make_args = shlex.split("make -C ../taudac-driver-dkms/src/ "
                    "{} kernelver={}{}+ prefix=/tmp release"
                    .format(cross_compile_args, kver, pver))
            subprocess.check_call(make_args)
        # git add new modules
        git_args = shlex.split(git_cmd + "add lib/")
        subprocess.check_call(git_args)
        # git commit
        git_args = shlex.split(git_cmd + "commit -am '{}'"
                .format(subprocess.check_output(
                        ["cat", "../modules/.git/taudac_git_tag"])[1:]))
        subprocess.check_call(git_args)
        # git tag
        git_args = shlex.split(git_cmd + "tag "
                "rpi-volumio-{}-taudac-modules".format(kver))
        subprocess.check_call(git_args)
        # git push
        git_args = shlex.split(git_cmd + "log "
                "--oneline --decorate=on origin/master..")
        subprocess.check_call(git_args)
        if query_yes_no("Do you want to publish?"):
            git_args = shlex.split(git_cmd + "push")
            subprocess.check_call(git_args)
            git_args.append("--tags")
            subprocess.check_call(git_args)

if __name__ == '__main__':
    # check if we need to cross compile
    machine = subprocess.check_output("uname -m", shell=True)
    if re.match(IS_RASPI_RE, machine) is not None:
        main()
    else:
        os.environ["PATH"] += os.pathsep + os.path.abspath(CROSS_COMPILE_PATH)
        main(CROSS_COMPILE_ARGS)
