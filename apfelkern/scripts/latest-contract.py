#!/usr/bin/env python3
"""Select the latest published stable bot contract, independently of server releases."""
import json
import os
import re
import urllib.request

url = "https://api.github.com/repos/crumble-project/bot/releases?per_page=100"
releases = []
while url:
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as response:
        page = json.load(response)
        if not isinstance(page, list):
            raise ValueError("Expected a release list")
        releases.extend(page)
        links = response.headers.get("Link", "")
        next_page = re.search(r'<([^>]+)>; rel="next"', links)
        url = next_page[1] if next_page else None
eligible = [release for release in releases
            if not release["draft"] and not release["prerelease"]
            and re.fullmatch(r"contract-v\d+\.\d+\.\d+", release["tag_name"])]
tag = max(eligible, key=lambda release: release["published_at"])["tag_name"] if eligible else ""
if not tag:
    print("No published stable contract release; retaining the explicit local export pin.")
else:
    print(tag)
if os.environ.get("GITHUB_OUTPUT"):
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"tag={tag}\n")
