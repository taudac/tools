#!/usr/bin/env python3

import argparse
import json, re
import os, subprocess, shlex
from urllib.request import urlopen
from urllib.error import URLError, HTTPError

import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText


IS_RASPI_RE = r'arm(v[6-7](l|hf))$'
CROSS_COMPILE_ARGS = "ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-"
CROSS_COMPILE_PATH = os.path.expanduser("~") + "/src/raspberrypi"\
        "/tools/arm-bcm2708/gcc-linaro-arm-linux-gnueabihf-raspbian-x64/bin/"


class GitHubRepo:
    def __init__(self, user, project):
        self.GITHUB_API_URL = 'https://api.github.com/repos'
        self.user = user
        self.project = project

    def __iter__(self):
        self.n = 0
        return self

    def __next__(self):
        ret = self.log(max_count=1, revision="HEAD~{}".format(self.n))
        if ret is not None:
            self.n += 1
            return ret[0]
        else:
            raise StopIteration

    def log(self, max_count=10, revision="HEAD"):
        try:
            json_str = urlopen("{}/{}/{}/commits?per_page={}&sha={}"
                    .format(self.GITHUB_API_URL, self.user, self.project,
                            max_count, revision)).read()
            commits = json.loads(json_str.decode('utf-8'))
        except (HTTPError, URLError) as e:
            print(e)
            return

        messages = []
        for c in commits:
            messages.append(
                    (c['sha'][0:8], c['commit']['message'].split('\n')[0]))
        return messages


def send_email(subject='', body=''):
    msg = MIMEMultipart()
    msg['From'] = args.sender
    msg['To'] = args.recipient
    msg['Subject'] = subject
    msg.attach(MIMEText(body, 'plain'))

    print("Sending email...")
    server = smtplib.SMTP(args.smtp_server, args.smtp_server_port)
    server.starttls()
    server.login(args.smtp_user, args.smtp_pass)
    server.send_message(msg)
    server.quit()


def query_yes_no(question):
    if args.assume_yes:
        return True

    yes = {'yes', 'y', ''}
    no = {'no', 'n'}

    print("{} [Y/n] ".format(question), end='')
    while True:
        choice = input().lower()
        if choice in yes:
            return True
        elif choice in no:
            return False
        else:
            print("Please respond with 'yes' or 'no' ", end='')


def main(cross_compile_args=""):
    hexxeh = GitHubRepo("Hexxeh", "rpi-firmware")
    taudac = GitHubRepo("taudac", "modules")
    git_cmd = "git -C ../modules/ "

    # get latest supported kernel version
    if args.current_version is not None:
        ckver = args.current_version
    else:
        last_commit = taudac.log(1)
        if last_commit is None:
            print("Failed reading taudac log!")
            return
        ckver = re.match(r'taudac-.* for ([\d\.]+)', last_commit[0][1]).group(1)

    print("Latest supported kernel is {}".format(ckver))

    # check if newer kernels are available
    pending = []
    for c in hexxeh:
        m = re.match(r'kernel:? [Bb]ump to ([\d\.]+)', c[1])
        if m is not None:
            nkver = m.group(1)
            if nkver <= ckver or nkver in [v[1] for v in pending]:
                break
            else:
                print("New kernel available: {}".format(nkver))
                pending.append((c[0], nkver))

    if not pending:
        print("Up-to-date with latest 'Hexxeh' kernel")
        return

    if not query_yes_no("Do you want to build new modules?"):
        return

    print("Updating working directory...")
    git_args = shlex.split(git_cmd + "pull --ff-only")
    subprocess.check_call(git_args)

    # download sources and build modules for each new kernel
    for sha, kver in sorted(pending, key=lambda x: x[1]):
        # download
        gks_args = ["./get-rpi-kernel-sources.sh", sha]
        if args.directory is not None:
            gks_args.insert(1, "-d{}".format(args.directory))
        if args.working_directory is not None:
            gks_args.insert(1, "-w{}".format(args.working_directory))
        subprocess.check_call(gks_args)
        # remove old modules
        subprocess.check_call("rm -rf ../modules/lib", shell=True)
        # launch make
        for pver in ["", "-v7", "-v7l"]:
            make_args = shlex.split("make --no-print-directory "
                    "-C ../taudac-driver-dkms/src/ "
                    "{} kernelver={}{}+ prefix={} release"
                    .format(cross_compile_args, kver, pver, args.directory))
            subprocess.check_call(make_args)
        # git add new modules
        git_args = shlex.split(git_cmd + "add lib/")
        subprocess.check_call(git_args)
        # git commit
        with open('../modules/.git/taudac_git_tag', 'r') as f:
            msg = f.read().lstrip('#').rstrip()
        git_args = shlex.split(git_cmd + "commit -am '{}'".format(msg))
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
        # send notification email
        if args.command == 'email':
            send_email("TauDAC modules for kernel {}".format(kver),
                    "TauDAC modules for kernel version {} have been built.".format(kver) )

if __name__ == '__main__':
    # parse arguments
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('-y', '--yes', '--assume-yes',
            dest='assume_yes', action='store_true',
            help='assume "yes" as answer to all prompts and run non-interactively')
    parser.add_argument('-d', '--directory', metavar='<DIR>', nargs='*', default='/tmp',
            help='store the sources in DIR, defaults to "/tmp"')
    parser.add_argument('-w', '--working-directory', metavar='<DIR>', nargs='*', default='/tmp',
            help='use DIR as working directory, defaults to "/tmp"')
    parser.add_argument('-C', '--current-version', metavar='<VER>',
            help='assume VER is the latest supported kernel version')

    # sub command email
    subparsers = parser.add_subparsers(dest='command', metavar='<command>')
    email_parser = subparsers.add_parser('email',
            help='send notification email if new modules have been built')
    email_parser.add_argument('--to', metavar='<address>',
            required=True, dest='recipient',
            help='the recipient email address')
    email_parser.add_argument('--from', metavar='<address>',
            required=True, dest='sender',
            help='the sender email address')
    email_parser.add_argument('-u', '--smtp-user', metavar='<username>',
            required=True,
            help='username for SMTP server login')
    email_parser.add_argument('-p', '--smtp-pass', metavar='<password>',
            required=True,
            help='password for SMTP server login')
    email_parser.add_argument('-S', '--smtp-server', metavar='<host>',
            required=True,
            help='the outgoing SMTP server to use')
    email_parser.add_argument('-P', '--smtp-server-port', metavar='<port>',
            default=587,
            help='the outgoing SMTP server port, defaults to 587')
    args = parser.parse_args()

    try:
        # check if we need to cross compile
        machine = subprocess.check_output("uname -m", shell=True)
        if re.match(IS_RASPI_RE, machine.decode('utf-8')) is not None:
            main()
        else:
            os.environ["PATH"] += os.pathsep + os.path.abspath(CROSS_COMPILE_PATH)
            main(CROSS_COMPILE_ARGS)
    except subprocess.CalledProcessError as e:
        note = ("command '{}' returned error code {}".format(e.cmd, e.returncode))
        print(note)
        # send notification email
        if args.command == 'email':
            send_email("Building TauDAC modules failed", note)

# vim: ts=4 sw=4 sts=4 et
