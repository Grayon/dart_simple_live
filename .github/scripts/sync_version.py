#!/usr/bin/env python3
"""从 Git Tag 自动生成版本号并更新 pubspec.yaml / version JSON。

用法:
  python3 .github/scripts/sync_version.py --tag <tag> --pubspec <path> [--version-json <path>]

示例:
  python3 .github/scripts/sync_version.py --tag dev_v1.11.5 --pubspec simple_live_app/pubspec.yaml
  python3 .github/scripts/sync_version.py --tag dev_tv_v1.6.7_202607111430 --pubspec simple_live_tv_app/pubspec.yaml
  python3 .github/scripts/sync_version.py --tag v1.11.5 --pubspec simple_live_app/pubspec.yaml --version-json assets/app_version.json
  python3 .github/scripts/sync_version.py --tag tv_v1.6.7 --pubspec simple_live_tv_app/pubspec.yaml --version-json assets/tv_app_version.json

Tag 格式:
  dev_v<version>      -> App Dev 版
  v<version>          -> App Release 版
  dev_tv_v<version>   -> TV Dev 版 (可加 _YYYYMMDDHHMM 时间戳后缀)
  tv_v<version>       -> TV Release 版

版本号计算:
  1.11.5 -> version: 1.11.5+11105 (build = major*10000 + minor*100 + patch)
"""

import argparse
import json
import re
import sys


def parse_tag(tag):
    """从 tag 中提取纯版本号字符串。

    支持的格式:
      dev_v1.11.5
      v1.11.5
      dev_tv_v1.6.7
      dev_tv_v1.6.7_202607111430
      tv_v1.6.7
    """
    # 去掉前缀 (dev_tv_v / dev_v / tv_v / v)
    m = re.match(r'^(?:dev_tv_v|dev_v|tv_v|v)(.+)', tag)
    if not m:
        print(f'ERROR: tag "{tag}" 不符合版本号格式', file=sys.stderr)
        sys.exit(1)

    raw = m.group(1)
    # 去掉时间戳后缀 (如 _202607111430)
    raw = re.sub(r'_\d{12}$', '', raw)
    # 去掉可能的 build 号后缀 (如 -beta, -alpha)
    raw = raw.split('-')[0]

    # 验证是 x.y.z 格式
    if not re.match(r'^\d+\.\d+\.\d+$', raw):
        print(f'ERROR: 从 tag "{tag}" 提取的版本号 "{raw}" 不是 x.y.z 格式', file=sys.stderr)
        sys.exit(1)

    return raw


def compute_build_number(version):
    """计算 build number: major*10000 + minor*100 + patch。

    1.11.5  -> 1*10000 + 11*100 + 5 = 11105
    1.6.7   -> 1*10000 + 6*100 + 7   = 10607
    """
    parts = [int(x) for x in version.split('.')]
    while len(parts) < 3:
        parts.append(0)
    return parts[0] * 10000 + parts[1] * 100 + parts[2]


def update_pubspec(pubspec_path, version, build_num):
    """更新 pubspec.yaml 中的 version 行。"""
    with open(pubspec_path, 'r', encoding='utf-8') as f:
        content = f.read()

    new_line = f'version: {version}+{build_num}'
    # 匹配 version: x.y.z+build 或 version: x.y.z
    pattern = r'^version:\s*\S+.*$'

    if re.search(pattern, content, re.MULTILINE):
        content = re.sub(pattern, new_line, content, count=1, flags=re.MULTILINE)
    else:
        print(f'ERROR: {pubspec_path} 中未找到 version 行', file=sys.stderr)
        sys.exit(1)

    with open(pubspec_path, 'w', encoding='utf-8') as f:
        f.write(content)

    print(f'  pubspec: {new_line}')


def update_version_json(json_path, version, build_num):
    """更新 version JSON 文件。"""
    with open(json_path, 'r', encoding='utf-8') as f:
        data = json.load(f)

    data['version'] = version
    data['version_num'] = build_num

    with open(json_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=4)
        f.write('\n')

    print(f'  version json: version={version}, version_num={build_num}')


def main():
    parser = argparse.ArgumentParser(description='从 Git Tag 同步版本号')
    parser.add_argument('--tag', required=True, help='Git tag 名称')
    parser.add_argument('--pubspec', required=True, help='pubspec.yaml 路径')
    parser.add_argument('--version-json', default=None, help='version JSON 文件路径 (可选, Release 版用)')
    args = parser.parse_args()

    print(f'同步版本号: tag={args.tag}')
    print(f'  pubspec: {args.pubspec}')
    if args.version_json:
        print(f'  version json: {args.version_json}')

    version = parse_tag(args.tag)
    build_num = compute_build_number(version)

    update_pubspec(args.pubspec, version, build_num)

    if args.version_json:
        update_version_json(args.version_json, version, build_num)

    print(f'完成: {version}+{build_num}')


if __name__ == '__main__':
    main()
