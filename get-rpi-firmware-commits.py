#!/usr/bin/env python2.7
import urllib2, json
import argparse

GITHUB_API_URL = 'https://api.github.com/repos'
USER = 'Hexxeh'
REPO = 'rpi-firmware'

def main(args):
    json_str = urllib2.urlopen(
            "{}/{}/{}/commits".format(GITHUB_API_URL, USER, REPO)).read()
    commits = json.loads(json_str)

    for c in commits:
        print c['sha'][0:8], c['commit']['message'].split('\n')[0]

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    args = parser.parse_args()
    main(args)
