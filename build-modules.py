#!/usr/bin/env python3

import argparse
import sys
import json, re
import os, subprocess, shlex
from shutil import rmtree
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
from packaging import version

import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email import encoders

RASPI32_SUFFIXES = ['', '-v7', '-v7l']
RASPI64_SUFFIXES = ['-v8', '-v8-16k']
RASPI_SUFFIXES = RASPI32_SUFFIXES + RASPI64_SUFFIXES
IS_RASPI32_RE = r'arm(v[6-7](l|hf))$'
IS_RASPI64_RE = r'aarch64$'
CROSS_COMPILE_ARGS_32 = ['ARCH=arm', 'CROSS_COMPILE=arm-linux-gnueabihf-']
CROSS_COMPILE_ARGS_64 = ['ARCH=arm64', 'CROSS_COMPILE=aarch64-linux-gnu-']


class GitHubRepo:
    def __init__(self, user, project, token=None):
        self.GITHUB_API_URL = 'https://api.github.com/repos'
        self.user = user
        self.project = project
        if token is None:
            self.token = os.getenv('GITHUB_TOKEN')
            if self.token is None:
                print(f"Warning: {user}@{project}: GITHUB_TOKEN environment variable not set.")
            else:
                print(f"Info: {user}@{project}: Using GITHUB_TOKEN environment variable.")
        else:
            self.token = token
            print(f"Info: {user}@{project}: Using provided token.")

    def __iter__(self):
        self.n = 0
        return self

    def __next__(self):
        ret = self.log(max_count=1, revision=f"HEAD~{self.n}")
        if ret is not None:
            self.n += 1
            return ret[0]
        else:
            raise StopIteration

    def log(self, max_count=10, revision="HEAD"):
        try:
            url = f"{self.GITHUB_API_URL}/{self.user}/{self.project}/commits?per_page={max_count}&sha={revision}"
            request = Request(url)
            if self.token:
                request.add_header("Authorization", f"token {self.token}")
            json_str = urlopen(request).read()
            commits = json.loads(json_str.decode('utf-8'))
        except HTTPError as e:
            if e.code == 403:
                print("HTTP Error 403: Rate limit exceeded.\n"
                      "Consider setting the GITHUB_TOKEN environment "
                      "variable to increase your rate limit.")
            sys.exit(1)
        except URLError as e:
            print(e)
            raise

        messages = []
        for c in commits:
            messages.append(
                    (c['sha'][0:8], c['commit']['message'].split('\n')[0]))
        return messages


def send_email(subject='', body='', filename=None):
    msg = MIMEMultipart()
    msg['From'] = args.sender
    msg['To'] = args.recipient
    msg['Subject'] = subject
    msg.attach(MIMEText(body, 'plain'))

    if filename is not None:
        part = MIMEBase('application', "octet-stream")
        with open(filename, 'rb') as file:
            part.set_payload(file.read())
        encoders.encode_base64(part)
        part.add_header('Content-Disposition',
                f'attachment; filename="{os.path.basename(filename)}"')
        msg.attach(part)

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

    print(f"{question} [Y/n] ", end='')
    while True:
        choice = input().lower()
        if choice in yes:
            return True
        elif choice in no:
            return False
        else:
            print("Please respond with 'yes' or 'no' ", end='')


def call(cmd, **kwargs):
    if not isinstance(cmd, list):
        cmd = shlex.split(cmd)
    if args.log_file is not None:
        with open(args.log_file, 'a+') as file:
            subprocess.check_call(cmd, stdout=file, stderr=file, **kwargs)
    subprocess.check_call(cmd, **kwargs)


def notify_done(kver):
    subject = f"TauDAC modules for kernel {kver}"
    body = f"TauDAC modules for kernel version {kver} have been built."
    print(body)
    if args.command == 'email':
        send_email(subject, body)


def notify_except(note):
    subject = "Building TauDAC modules failed"
    print(note)
    if args.command == 'email':
        if args.log_file is not None:
            send_email(subject, note, args.log_file)
        else:
            send_email(subject, note)


def main():
    firmware = GitHubRepo("raspberrypi", "firmware")
    taudac = GitHubRepo("taudac", "modules")
    git_cmd = ['git', '-C', '../modules/']

    # get latest supported kernel version
    if args.current_version is not None:
        ckver = args.current_version
    else:
        last_commits = taudac.log(2)
        if last_commits is None:
            print("Failed reading taudac log!")
            return
        for commit in last_commits:
            m = re.match(r'taudac-.* for ([\d\.]+)', commit[1])
            if m:
                ckver = m.group(1)
                break
        else:
            print("Didn't find supported kernel version!")
            return

    print(f"Latest supported kernel is {ckver}")

    # check if newer kernels are available
    pending = []
    for c in firmware:
        m = re.match(r'kernel:? ([Bb]ump|[Uu]pdate) to ([\d\.]+)', c[1])
        if m is not None:
            nkver = m.group(2)
            if version.parse(nkver) <= version.parse(ckver):
                break
            if nkver in [v[1] for v in pending]:
                print(f"WARNING: Skipping {nkver}, already in pending list.")
                continue
            pending.append((c[0], nkver))
            print(f"[{len(pending):02d}] New kernel available: {pending[-1][1]} ({pending[-1][0]})")

    if not pending:
        print("Up-to-date with latest kernel")
        return

    if not query_yes_no("Do you want to build new modules?"):
        return

    print("Updating working directory...")
    call(git_cmd + ['pull', '--ff-only'])

    pending = sorted(pending, key=lambda x: version.parse(x[1]))
    if args.max_versions:
        pending = pending[:args.max_versions]

    # download sources and build modules for each new kernel
    for sha, kver in pending:
        # download
        gks_args = ['./get-rpi-kernel-sources.sh', sha]
        if args.directory is not None:
            gks_args.insert(1, f"-d{args.directory}")
        if args.working_directory is not None:
            gks_args.insert(1, f"-w{args.working_directory}")
        call(gks_args)
        # remove old modules
        rmtree('../modules/lib', ignore_errors=True)

        # check if we need to cross compile
        machine = subprocess.check_output("uname -m", shell=True).decode('utf-8').strip()

        # launch make
        for pver in RASPI_SUFFIXES:
            cross_compile_args = []

            if pver in RASPI32_SUFFIXES:
                if not re.match(IS_RASPI32_RE, machine):
                    cross_compile_args = CROSS_COMPILE_ARGS_32
            elif pver in RASPI64_SUFFIXES:
                if not re.match(IS_RASPI64_RE, machine):
                    cross_compile_args = CROSS_COMPILE_ARGS_64

            make_args = ['make', '--no-print-directory', '--always-make',
                    '-C', '../taudac-driver-dkms/src/',
                    'INSTALL_TO_ORIGDIR=1', *cross_compile_args, *args.extra_make_args,
                    f'kernelver={kver}{pver}+',
                    f'prefix={args.directory}', 'release']
            call(make_args)
        # git add new modules
        call(git_cmd + ['add', 'lib/'])
        # git commit
        with open('../modules/.git/taudac_git_tag', 'r') as f:
            msg = f.read().lstrip('#').rstrip()
        call(git_cmd + ['commit', '-am', msg])
        # git tag
        if not args.do_not_tag:
            call(git_cmd + ['tag', '--force',
                    f'rpi-volumio-{kver}-taudac-modules'])
        # git push
        call(git_cmd + ['log', '--oneline', '--decorate=on', 'origin/master..'])
        if query_yes_no("Do you want to publish?"):
            call(git_cmd + ['push'],           timeout=30)
            call(git_cmd + ['push', '--tags'], timeout=30)
        # done
        notify_done(kver)


def dir_path(path):
    if os.path.isdir(path):
        return path
    else:
        raise argparse.ArgumentTypeError(f"'{path}' is not a valid path")


def new_file_path(file):
    if os.path.isfile(file):
        raise argparse.ArgumentTypeError(f"'{file}' exists")
    else:
        return file


if __name__ == '__main__':
    # parse arguments
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('-y', '--yes', '--assume-yes',
            dest='assume_yes', action='store_true',
            help='assume "yes" as answer to all prompts and run non-interactively')
    parser.add_argument('-d', '--directory', metavar='<DIR>',
            default='/tmp', type=dir_path,
            help='store the sources in DIR, defaults to "/tmp"')
    parser.add_argument('-w', '--working-directory', metavar='<DIR>',
            default='/tmp', type=dir_path,
            help='use DIR as working directory, defaults to "/tmp"')
    parser.add_argument('-l', '--log-file', metavar='<FILE>',
            type=new_file_path,
            help='write subprocess output to FILE')
    parser.add_argument('-m', '--max-versions', metavar='<N>',
            type=int,
            help='stop after building <N> versions')
    parser.add_argument('-C', '--current-version', metavar='<VER>',
            help='assume VER is the latest supported kernel version')
    parser.add_argument('-e', '--extra-make-args', metavar='<ARGS>',
            default='', type=str,
            help='extra arguments to pass to the build process (make)')
    parser.add_argument('-n', '--do-not-tag',
            dest='do_not_tag', action='store_true',
            help='do not tag the new modules in the git repository')

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
    args.extra_make_args = args.extra_make_args.split()

    try:
        main()
    except subprocess.CalledProcessError as e:
        note = f"command '{e.cmd}' returned error code {e.returncode}"
        notify_except(note)
    except subprocess.TimeoutExpired as e:
        note = f"command '{e.cmd}' expired"
        notify_except(note)

# vim: ts=4 sw=4 sts=4 et
