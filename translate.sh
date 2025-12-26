#!/bin/bash
set -e

UPSTREAM_REPO="https://github.com/dani-garcia/vaultwarden.git"
TARGET_DIR="templates"
TMP_DIR=$(mktemp -d)
LANGS=("zh-cn" "zh-tw" "ja" "ko")
MAX_JOBS=16  # 并发任务数

# 不翻译的词汇列表
KEEP_WORDS="Vaultwarden Bitwarden Send SSO URL FIDO2 WebAuthn IP DNS NTP"

# 翻译函数
translate_file() {
  local src_file="$1"
  local dest_file="$2"
  local lang="$3"
  
  local content=$(cat "$src_file")
  
  local lang_name
  case "$lang" in
    zh-cn) lang_name="简体中文" ;;
    zh-tw) lang_name="繁体中文" ;;
    ja) lang_name="日语" ;;
    ko) lang_name="韩语" ;;
    *) lang_name="$lang" ;;
  esac

  local system_prompt="你是一个专业的翻译助手。请将用户提供的 Handlebars 模板文本翻译为${lang_name}，并严格保留 Handlebars 模板语法不变。

重要规则：
1. 保持以下词汇不翻译，原样输出：${KEEP_WORDS}
2. 严格保留所有 Handlebars 语法标记（{{}}、#、/、> 等）
3. 保留所有 HTML 标签和属性
4. 仅返回翻译后的模板内容，不要添加任何注释或说明"

  local payload=$(jq -n \
    --arg model "deepseek-chat" \
    --arg system "$system_prompt" \
    --arg text "$content" '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $text}
      ],
      temperature: 0.2
    }')
  
  local response=$(curl -s https://api.deepseek.com/chat/completions \
    -H "Authorization: Bearer $DEEPSEEK_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")
  
  echo "$response" | jq -r '.choices[0].message.content' > "$dest_file"
}

# 导出函数供并行使用
export -f translate_file
export DEEPSEEK_API_KEY
export KEEP_WORDS

# 获取最新 tag
echo "Fetching latest tag..."
latest_tag=$(git ls-remote --tags --sort="v:refname" "$UPSTREAM_REPO" | \
  grep -o 'refs/tags/.*' | grep -v '{}' | tail -n1 | sed 's#refs/tags/##')
echo "Latest tag: $latest_tag"

# 检查 tag 是否已存在
if git tag | grep -q "^${latest_tag}$"; then
  echo "Tag $latest_tag already exists. Exiting."
  exit 0
fi

# Clone 仓库
echo "Cloning repository..."
git clone --depth 1 --branch "$latest_tag" "$UPSTREAM_REPO" "$TMP_DIR"
NEW_TEMPLATES_DIR="$TMP_DIR/src/static/templates"

# 对每种语言进行翻译
for lang in "${LANGS[@]}"; do
  echo "Processing language: $lang"
  OUT_DIR="templates.$lang"
  mkdir -p "$OUT_DIR"
  
  # 收集需要翻译的文件
  translate_jobs=()
  
  while IFS= read -r new_file; do
    relative_path="${new_file#$NEW_TEMPLATES_DIR/}"
    old_file="$TARGET_DIR/$relative_path"
    translated_file="$OUT_DIR/$relative_path"
    
    # 如果旧文件存在且内容一致，则跳过
    if [[ -f "$old_file" ]] && cmp -s "$new_file" "$old_file"; then
      echo "  Unchanged: $relative_path, skipping"
      continue
    fi
    
    mkdir -p "$(dirname "$translated_file")"
    translate_jobs+=("$new_file|$translated_file|$lang")
  done < <(find "$NEW_TEMPLATES_DIR" -type f -name "*.hbs")
  
  # 并行翻译
  if [ ${#translate_jobs[@]} -gt 0 ]; then
    echo "  Translating ${#translate_jobs[@]} files..."
    printf '%s\n' "${translate_jobs[@]}" | \
      xargs -P "$MAX_JOBS" -I {} bash -c '
        IFS="|" read -r src dest lang <<< "{}"
        echo "    Translating: $(basename "$src") -> $lang"
        translate_file "$src" "$dest" "$lang"
      '
  fi
done

# 更新模板目录
echo "Updating templates directory..."
rm -rf "$TARGET_DIR"
cp -r "$NEW_TEMPLATES_DIR" "$TARGET_DIR"

# 清理临时目录
rm -rf "$TMP_DIR"

# 提交变更
echo "Committing changes..."
git add .

if git diff --cached --quiet; then
  echo "No changes to commit."
else
  git commit -m "Update templates to $latest_tag"
  git tag "$latest_tag"
  git push origin main --tags
fi

echo "Done!"
