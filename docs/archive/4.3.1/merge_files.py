# === ARCHIVED merge_files.py ===
# 来源版本: 4.3.1 中间 version
# 生成日期: 2026-07-15 (mtime)
# 状态: DEPRECATED — 永久禁止作为任何新生成的起点, 仅作指纹比对素材
# === END META ===

import os

# 定义需要合并的文件列表（按你图片中的文件顺序）
files_to_merge = [
    "Dockerfile",
    "entrypoint.sh",
    "gate.js",
    "init-nim-keys.sh",
    "litestream.yml",
    "package.json",
    "README.md"
]

output_file = "omn-merge-v4.3.0.md"

def merge():
    with open(output_file, "w", encoding="utf-8") as outfile:
        outfile.write(f"# OmniRoute Project Merge - v4.3.0\n\n")
        
        for filename in files_to_merge:
            if os.path.exists(filename):
                print(f"正在合并: {filename}")
                outfile.write(f"## {filename}\n\n")
                
                # 根据文件扩展名确定代码块语法高亮
                ext = filename.split('.')[-1]
                lang = "sh" if ext == "sh" else ext
                if filename == "Dockerfile": lang = "dockerfile"
                if ext == "yml": lang = "yaml"
                
                outfile.write(f"```{lang}\n")
                with open(filename, "r", encoding="utf-8") as infile:
                    outfile.write(infile.read())
                outfile.write("\n```\n\n")
            else:
                print(f"跳过: {filename} (文件不存在)")

    print(f"\n完成！合并后的文件已保存至: {output_file}")

if __name__ == "__main__":
    merge()