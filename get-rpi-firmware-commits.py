#!/usr/bin/env python2.7
import urllib2, json
import argparse

GITHUB_API_URL = 'https://api.github.com/repos'
USER = 'raspberrypi'
REPO = 'firmware'

def main(args):
    try:
        json_str = urllib2.urlopen(
                "{}/{}/{}/commits?per_page={}&sha={}"
                .format(GITHUB_API_URL, USER, REPO, args.max_count, args.revision)).read()
        commits = json.loads(json_str)
    except urllib2.HTTPError as e:
        print e
        return

    for c in commits:
        print c['sha'][0:8], c['commit']['message'].split('\n')[0]

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("-n", "--max-count", metavar="<number>", default=10,
            help="print the number of commits, defaults to 10")
    parser.add_argument("-r", "--revision", metavar="<sha>", default="HEAD",
            help="start with given revision, defaults to HEAD")
    args = parser.parse_args()
    main(args)

