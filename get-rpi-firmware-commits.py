#!/usr/bin/env python2.7
import urllib2, json
import argparse

GITHUB_API_URL = 'https://api.github.com/repos'
USER = 'Hexxeh'
REPO = 'rpi-firmware'

def main(args):
    json_str = urllib2.urlopen(
            "{}/{}/{}/commits?per_page={}"
            .format(GITHUB_API_URL, USER, REPO, args.max_count)).read()
    commits = json.loads(json_str)

    for c in commits:
        print c['sha'][0:8], c['commit']['message'].split('\n')[0]

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("-n", "--max-count", metavar="<number>", default=10,
            help="print the number of commits, defaults to 10")
    args = parser.parse_args()
    main(args)
