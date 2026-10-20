#!/usr/bin/env python3
"""Update Blog Home template (post 56) UAG container be170361: GIF -> rankings-bot MP4."""

from __future__ import annotations

import json
import re
import subprocess
import sys

TEMPLATE_ID = 56
BLOCK_ID = "be170361"
VIDEO_URL = (
    "https://www.example.com/wp-content/uploads/2026/05/"
    "grok-video-a1fee053-2343-4013-a0de-0445458248cf-1.mp4"
)
ATTACHMENT_ID = 321


def fetch_content() -> str:
    cmd = [
        "sudo",
        "docker",
        "exec",
        "alfa_db_1",
        "mysql",
        "-uwordpress",
        "-pwordpress",
        "wordpress",
        "-N",
        "-e",
        f"SELECT post_content FROM wp_posts WHERE ID={TEMPLATE_ID};",
    ]
    raw = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
    return raw.decode("utf-8", errors="replace")


def build_video_attachment() -> dict:
    """Mirror backgroundImageDesktop shape from existing block."""
    return {
        "id": ATTACHMENT_ID,
        "title": "ALFa hero background video",
        "filename": "grok-video-a1fee053-2343-4013-a0de-0445458248cf-1.mp4",
        "url": VIDEO_URL,
        "link": "https://www.example.com/alfa-hero-background-video/",
        "alt": "",
        "author": "1",
        "description": "",
        "caption": "",
        "name": "alfa-hero-background-video",
        "status": "inherit",
        "uploadedTo": 0,
        "date": "2026-05-29T00:00:00.000Z",
        "modified": "2026-05-29T00:00:00.000Z",
        "menuOrder": 0,
        "mime": "video/mp4",
        "type": "video",
        "subtype": "mp4",
        "icon": "https://www.example.com/wp-includes/images/media/video.svg",
        "dateFormatted": "May 29, 2026",
        "nonces": {"update": "", "delete": "", "edit": ""},
        "editLink": (
            f"https://www.example.com/wp-admin/post.php?"
            f"post={ATTACHMENT_ID}&action=edit"
        ),
        "meta": False,
        "authorName": "alfa",
        "authorLink": "https://www.example.com/wp-admin/profile.php",
        "filesizeInBytes": 3412144,
        "filesizeHumanReadable": "3 MB",
        "context": "",
        "height": 0,
        "width": 0,
        "orientation": "landscape",
        "compat": {"item": "", "meta": ""},
    }


def patch_block(content: str) -> str:
    pattern = re.compile(
        r"<!-- wp:uagb/container (\{.*?\}) -->",
        re.DOTALL,
    )

    def replacer(match: re.Match[str]) -> str:
        raw = match.group(1)
        if BLOCK_ID not in raw:
            return match.group(0)
        data = json.loads(raw)
        data["backgroundType"] = "video"
        data["backgroundVideo"] = build_video_attachment()
        data["backgroundVideoOpacity"] = 35
        data.pop("backgroundImageDesktop", None)
        data["backgroundSizeDesktop"] = "contain"
        data["backgroundSizeTablet"] = "contain"
        data["backgroundSizeMobile"] = "contain"
        data["backgroundAttachmentDesktop"] = "fixed"
        data["backgroundAttachmentTablet"] = "fixed"
        data["backgroundAttachmentMobile"] = "fixed"
        new_json = json.dumps(data, separators=(",", ":"))
        new_json = new_json.replace("/", "\\/")
        return f"<!-- wp:uagb/container {new_json} -->"

    updated, count = 0, 0
    out = []
    last = 0
    for match in pattern.finditer(content):
        out.append(content[last : match.start()])
        replacement = replacer(match)
        out.append(replacement)
        if replacement != match.group(0):
            count += 1
        last = match.end()
    out.append(content[last:])
    updated = "".join(out)
    if count != 1:
        raise SystemExit(f"Expected 1 block patch, got {count}")
    return updated


def write_content(content: str) -> None:
    host_path = "/tmp/blog-home-patched.txt"
    wp_path = (
        "/var/lib/docker/volumes/alfa1_wp_data/_data/blog-home-patched.txt"
    )
    with open(host_path, "w", encoding="utf-8") as fh:
        fh.write(content)
    subprocess.check_call(["sudo", "cp", host_path, wp_path])
    subprocess.check_call(
        [
            "bash",
            "/home/operator/alfaqd-website/bin/wp-cli.sh",
            "eval",
            (
                f'$c = file_get_contents("/var/www/html/blog-home-patched.txt"); '
                f'$r = wp_update_post(array("ID" => {TEMPLATE_ID}, "post_content" => $c), true); '
                'if (is_wp_error($r)) { WP_CLI::error($r->get_error_message()); } '
                'WP_CLI::success("Updated template " . $r);'
            ),
        ]
    )


def main() -> None:
    content = fetch_content()
    if BLOCK_ID not in content:
        raise SystemExit(f"Block {BLOCK_ID} not found in template {TEMPLATE_ID}")
    patched = patch_block(content)
    write_content(patched)
    print(f"Updated wp_template post {TEMPLATE_ID}: hero background is now {VIDEO_URL}")


if __name__ == "__main__":
    main()
