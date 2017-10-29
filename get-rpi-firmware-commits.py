#!/usr/bin/python
import urllib2, json

GITHUB_API_URL = 'https://api.github.com/repos'
USER = 'Hexxeh'
REPO = 'rpi-firmware'

json_str = urllib2.urlopen(
        "{}/{}/{}/commits".format(GITHUB_API_URL, USER, REPO)).read()
commits = json.loads(json_str)

for c in commits:
    print c['sha'][0:8], c['commit']['message'].split('\n')[0]
