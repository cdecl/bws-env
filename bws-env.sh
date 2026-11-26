#!/usr/bin/env bash

# bws-env.sh - Bitwarden Secrets Manager (BWS) Flat Key-Value .env Sync Tool
# Architecture: Flat Key-Value (<service>/<filename>) with Whole-File content
# Example Key:  shynote/.env, bifrost/.env.local, web-api/.env.production
# Value:        Raw file content (preserves comments, empty lines, formatting)

# ANSI Color Codes
COLOR_RESET="\033[0m"
COLOR_BOLD="\033[1m"
COLOR_DIM="\033[2m"
COLOR_RED="\033[31m"
COLOR_GREEN="\033[32m"
COLOR_YELLOW="\033[33m"
COLOR_BLUE="\033[34m"
COLOR_MAGENTA="\033[35m"
COLOR_CYAN="\033[36m"
COLOR_GRAY="\033[90m"

CURRENT_DIR=$(basename "$PWD")
SERVICE_NAME="$CURRENT_DIR"
ENV_FILE="./.env"

TOKEN_FILE="$HOME/.config/bws/token"
TOKEN_SOURCE=""
SILENT_PROJECT_ID=""

# 1. BWS 토큰 점검 및 자동 로드
check_token() {
  if [ -n "$BWS_ACCESS_TOKEN" ]; then
    TOKEN_SOURCE="환경변수 (BWS_ACCESS_TOKEN)"
    return 0
  fi

  if [ -f "$TOKEN_FILE" ]; then
    local file_token
    file_token=$(tr -d '\r\n' < "$TOKEN_FILE" 2>/dev/null || true)
    if [ -n "$file_token" ]; then
      export BWS_ACCESS_TOKEN="$file_token"
      TOKEN_SOURCE="설정 파일 ($TOKEN_FILE)"
      return 0
    fi
  fi

  echo -e "\n${COLOR_YELLOW}${COLOR_BOLD}[!] BWS_ACCESS_TOKEN이 감지되지 않았습니다.${COLOR_RESET}"
  echo -e "Bitwarden Secrets Manager의 Access Token을 입력해 주세요."
  read -r -p "Access Token: " input_token
  input_token=$(echo "$input_token" | tr -d '\r\n')

  if [ -z "$input_token" ]; then
    echo -e "${COLOR_RED}토큰이 입력되지 않아 종료합니다.${COLOR_RESET}"
    exit 1
  fi

  export BWS_ACCESS_TOKEN="$input_token"

  echo ""
  read -r -p "이 토큰을 '$TOKEN_FILE'에 저장하여 다음부터 자동으로 불러올까요? [Y/n]: " save_ans
  if [[ ! "$save_ans" =~ ^[Nn]$ ]]; then
    mkdir -p "$(dirname "$TOKEN_FILE")"
    echo "$input_token" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo -e "${COLOR_GREEN}${COLOR_BOLD}성공:${COLOR_RESET} 토큰이 '$TOKEN_FILE'에 안전하게 저장되었습니다 (권한: 600)."
    TOKEN_SOURCE="설정 파일 ($TOKEN_FILE)"
  else
    TOKEN_SOURCE="현재 세션 (임시)"
  fi
}

# 2. 내부 저장용 프로젝트 ID 자동 확인 (사용자에게 노출하지 않음)
ensure_internal_project_id() {
  if [ -n "$SILENT_PROJECT_ID" ]; then
    return 0
  fi

  local p_json
  p_json=$(bws project list -o json 2>/dev/null || echo "[]")
  SILENT_PROJECT_ID=$(echo "$p_json" | jq -r '.[0].id // empty' 2>/dev/null || true)

  if [ -z "$SILENT_PROJECT_ID" ]; then
    # 계정에 프로젝트가 하나도 없는 경우에만 내부용 프로젝트 자동 1회 생성
    local create_res
    create_res=$(bws project create "default-vault" -o json 2>/dev/null || true)
    SILENT_PROJECT_ID=$(echo "$create_res" | jq -r '.id // empty' 2>/dev/null || true)
  fi
}

# 3. 전체 시크릿 JSON 조회 (프로젝트 구분 없이 계정 전체 flat 조회)
get_all_secrets_json() {
  bws secret list -o json 2>/dev/null || echo "[]"
}

# 4. 현재 활성 키 계산 (<service>/<filename>)
get_current_key() {
  local fname
  fname=$(basename "$ENV_FILE")
  echo "${SERVICE_NAME}/${fname}"
}

# 5. Diff 엔진 (로컬 파일 vs 원격 BWS 시크릿)
# exit code: 0=일치(SYNCED), 1=불일치(MODIFIED), 2=로컬만있음(LOCAL_ONLY), 3=원격만있음(REMOTE_ONLY), 4=둘다없음
render_diff() {
  local env_path="$1"
  local secret_key="$2"
  local secrets_json
  secrets_json=$(get_all_secrets_json)

  python3 -c '
import sys, os, json, difflib

env_path = sys.argv[1]
secret_key = sys.argv[2]
secrets = json.loads(sys.argv[3])

match = next((s for s in secrets if s.get("key") == secret_key), None)
rem_exists = match is not None
rem_val = match.get("value", "") if rem_exists else ""

loc_exists = os.path.isfile(env_path)
loc_val = ""
if loc_exists:
    with open(env_path, "r", encoding="utf-8", errors="replace") as f:
        loc_val = f.read()

print(f"\033[1m=== Diff: Local [{env_path}] vs Remote BWS [{secret_key}] ===\033[0m")

if not loc_exists and not rem_exists:
    print(f"\033[33m[!] 로컬 파일과 원격 BWS 시크릿이 모두 존재하지 않습니다.\033[0m\n")
    sys.exit(4)

if loc_exists and not rem_exists:
    print(f"상태: \033[36m\033[1m[LOCAL ONLY]\033[0m 원격 BWS에 시크릿 [{secret_key}] 이 없습니다.")
    print(f"로컬 파일 라인 수: {len(loc_val.splitlines())} lines\n")
    sys.exit(2)

if not loc_exists and rem_exists:
    print(f"상태: \033[35m\033[1m[REMOTE ONLY]\033[0m 로컬 파일 [{env_path}] 이 없습니다.")
    print(f"원격 시크릿 라인 수: {len(rem_val.splitlines())} lines\n")
    sys.exit(3)

if loc_val == rem_val:
    print(f"상태: \033[32m\033[1m[SYNCED]\033[0m 로컬 파일과 원격 BWS 시크릿이 완전히 일치합니다.\n")
    sys.exit(0)

print(f"상태: \033[33m\033[1m[MODIFIED]\033[0m 로컬과 원격 시크릿의 내용이 다릅니다.\n")

rem_lines = rem_val.splitlines(keepends=True)
loc_lines = loc_val.splitlines(keepends=True)

diff = difflib.unified_diff(
    rem_lines,
    loc_lines,
    fromfile=f"Remote BWS ({secret_key})",
    tofile=f"Local ({env_path})",
    lineterm=""
)

for line in diff:
    line_clean = line.rstrip("\r\n")
    if line_clean.startswith("---") or line_clean.startswith("+++"):
        print(f"\033[1m{line_clean}\033[0m")
    elif line_clean.startswith("@@"):
        print(f"\033[36m{line_clean}\033[0m")
    elif line_clean.startswith("+"):
        print(f"\033[32m{line_clean}\033[0m")
    elif line_clean.startswith("-"):
        print(f"\033[31m{line_clean}\033[0m")
    else:
        print(f" {line_clean}")
print()
sys.exit(1)
' "$env_path" "$secret_key" "$secrets_json"
}

# 6. Pull 서브메뉴
submenu_pull() {
  local secret_key
  secret_key=$(get_current_key)

  local loc_status="${COLOR_RED}(파일 없음)${COLOR_RESET}"
  if [ -f "$ENV_FILE" ]; then
    local l_count
    l_count=$(wc -l < "$ENV_FILE" | tr -d ' ')
    loc_status="${COLOR_GREEN}(존재함: ${l_count}줄)${COLOR_RESET}"
  fi

  echo -e "\n========================================================"
  echo -e " ${COLOR_BOLD}=== Pull: Remote BWS ➔ Local File ===${COLOR_RESET}"
  echo -e " • Service Name : ${COLOR_CYAN}${SERVICE_NAME}${COLOR_RESET}"
  echo -e " • Target File  : ${COLOR_YELLOW}${ENV_FILE}${COLOR_RESET} ${loc_status}"
  echo -e " • BWS Key      : ${COLOR_GREEN}${COLOR_BOLD}${secret_key}${COLOR_RESET}"
  echo -e "--------------------------------------------------------"

  local diff_code=0
  render_diff "$ENV_FILE" "$secret_key" || diff_code=$?

  if [ "$diff_code" -eq 0 ]; then
    echo -e "${COLOR_GREEN}원격과 로컬 파일이 이미 완전히 일치합니다.${COLOR_RESET}"
    read -r -p "엔터를 누르면 메인 메뉴로 돌아갑니다..." _any
    return
  fi

  if [ "$diff_code" -eq 2 ] || [ "$diff_code" -eq 4 ]; then
    echo -e "${COLOR_RED}Error:${COLOR_RESET} 원격 BWS에 가져올 시크릿 [${secret_key}] 이 없습니다."
    read -r -p "엔터를 누르면 메인 메뉴로 돌아갑니다..." _any
    return
  fi

  echo "작업을 선택하세요:"
  echo " 1) 지금 바로 로컬에 덮어쓰기 (Pull) [기존 파일 자동백업]"
  echo " 2) 대상 파일/키 변경"
  echo " 0) 취소 (메인 메뉴로 돌아가기)"
  echo "--------------------------------------------------------"
  read -r -p "선택하세요 [default: 1]: " p_choice
  p_choice=${p_choice:-1}

  case "$p_choice" in
    1)
      # 기존 파일 백업
      if [ -f "$ENV_FILE" ]; then
        local backup_path="${ENV_FILE}.$(date +%Y%m%d%H%M%S).bak"
        cp "$ENV_FILE" "$backup_path"
        echo -e "${COLOR_GRAY}기존 로컬 파일 백업 완료: $backup_path${COLOR_RESET}"
      fi

      local secrets_json
      secrets_json=$(get_all_secrets_json)

      python3 -c '
import sys, json

env_path = sys.argv[1]
secret_key = sys.argv[2]
secrets = json.loads(sys.argv[3])

match = next(s for s in secrets if s.get("key") == secret_key)
content = match.get("value", "")

with open(env_path, "w", encoding="utf-8") as f:
    f.write(content)
' "$ENV_FILE" "$secret_key" "$secrets_json"

      echo -e "${COLOR_GREEN}${COLOR_BOLD}성공:${COLOR_RESET} '$ENV_FILE' 파일에 원격 시크릿을 성공적으로 가져왔습니다 (Pull 완료)."
      read -r -p "엔터를 누르면 메인 메뉴로 돌아갑니다..." _any
      ;;
    2)
      action_change
      submenu_pull
      ;;
    *)
      echo -e "${COLOR_YELLOW}Pull 작업이 취소되었습니다.${COLOR_RESET}"
      ;;
  esac
}

# 7. Push 서브메뉴
submenu_push() {
  local secret_key
  secret_key=$(get_current_key)

  local loc_status="${COLOR_RED}(파일 없음)${COLOR_RESET}"
  if [ -f "$ENV_FILE" ]; then
    local l_count
    l_count=$(wc -l < "$ENV_FILE" | tr -d ' ')
    loc_status="${COLOR_GREEN}(존재함: ${l_count}줄)${COLOR_RESET}"
  fi

  echo -e "\n========================================================"
  echo -e " ${COLOR_BOLD}=== Push: Local File ➔ Remote BWS ===${COLOR_RESET}"
  echo -e " • Service Name : ${COLOR_CYAN}${SERVICE_NAME}${COLOR_RESET}"
  echo -e " • Target File  : ${COLOR_YELLOW}${ENV_FILE}${COLOR_RESET} ${loc_status}"
  echo -e " • BWS Key      : ${COLOR_GREEN}${COLOR_BOLD}${secret_key}${COLOR_RESET}"
  echo -e "--------------------------------------------------------"

  if [ ! -f "$ENV_FILE" ]; then
    echo -e "${COLOR_RED}Error:${COLOR_RESET} 로컬 '$ENV_FILE' 파일이 존재하지 않아 Push할 수 없습니다."
    read -r -p "엔터를 누르면 메인 메뉴로 돌아갑니다..." _any
    return
  fi

  local diff_code=0
  render_diff "$ENV_FILE" "$secret_key" || diff_code=$?

  if [ "$diff_code" -eq 0 ]; then
    echo -e "${COLOR_GREEN}로컬과 원격이 이미 일치합니다. Push할 내용이 없습니다.${COLOR_RESET}"
    read -r -p "엔터를 누르면 메인 메뉴로 돌아갑니다..." _any
    return
  fi

  local secrets_json
  secrets_json=$(get_all_secrets_json)

  local existing_id
  existing_id=$(echo "$secrets_json" | jq -r --arg key "$secret_key" '.[] | select(.key == $key) | .id' 2>/dev/null || true)

  local action_type="수정(Edit)"
  if [ -z "$existing_id" ] || [ "$existing_id" == "null" ]; then
    action_type="신규 생성(Create)"
    existing_id=""
  fi

  echo "작업을 선택하세요:"
  echo " 1) 지금 바로 BWS에 반영 (Push - ${action_type})"
  echo " 2) 대상 파일/키 변경"
  echo " 0) 취소 (메인 메뉴로 돌아가기)"
  echo "--------------------------------------------------------"
  read -r -p "선택하세요 [default: 1]: " p_choice
  p_choice=${p_choice:-1}

  case "$p_choice" in
    1)
      ensure_internal_project_id
      echo -e "${COLOR_BLUE}BWS 서버에 Push 중...${COLOR_RESET}"

      python3 -c '
import sys, subprocess

env_path = sys.argv[1]
secret_key = sys.argv[2]
proj_id = sys.argv[3]
existing_id = sys.argv[4]

with open(env_path, "r", encoding="utf-8", errors="replace") as f:
    content = f.read()

if existing_id:
    res = subprocess.run(["bws", "secret", "edit", "--value", content, existing_id], capture_output=True, text=True)
    if res.returncode != 0:
        print(f"\033[31m실패: {res.stderr.strip()}\033[0m")
        sys.exit(1)
    print(f"\033[32m\033[1m성공:\033[0m BWS 시크릿 [{secret_key}] 이 성공적으로 업데이트되었습니다.")
else:
    res = subprocess.run(["bws", "secret", "create", secret_key, content, proj_id], capture_output=True, text=True)
    if res.returncode != 0:
        print(f"\033[31m실패: {res.stderr.strip()}\033[0m")
        sys.exit(1)
    print(f"\033[32m\033[1m성공:\033[0m BWS 시크릿 [{secret_key}] 이 새로 생성되었습니다.")
' "$ENV_FILE" "$secret_key" "$SILENT_PROJECT_ID" "$existing_id"

      read -r -p "엔터를 누르면 메인 메뉴로 돌아갑니다..." _any
      ;;
    2)
      action_change
      submenu_push
      ;;
    *)
      echo -e "${COLOR_YELLOW}Push 작업이 취소되었습니다.${COLOR_RESET}"
      ;;
  esac
}

# 8. View
action_view() {
  local secret_key
  secret_key=$(get_current_key)
  local secrets_json
  secrets_json=$(get_all_secrets_json)

  python3 -c '
import sys, json

secret_key = sys.argv[1]
secrets = json.loads(sys.argv[2])

match = next((s for s in secrets if s.get("key") == secret_key), None)
if not match:
    print(f"\033[33m원격 BWS에 시크릿 키 [{secret_key}] 가 존재하지 않습니다.\033[0m")
    sys.exit(0)

val = match.get("value", "")
lines = val.splitlines()
line_cnt = len(lines)
byte_len = len(val.encode("utf-8"))

print(f"\033[1m=== Remote Secret [{secret_key}] Content ({line_cnt} lines, {byte_len} bytes) ===\033[0m\n")
for idx, line in enumerate(lines, 1):
    if line.strip().startswith("#"):
        print(f"\033[90m{idx:4d} | {line}\033[0m")
    elif "=" in line:
        k, v = line.split("=", 1)
        print(f"\033[90m{idx:4d} |\033[0m \033[36m{k}\033[0m=\033[32m{v}\033[0m")
    else:
        print(f"\033[90m{idx:4d} | {line}\033[0m")
print()
' "$secret_key" "$secrets_json"
}

# 9. List All (저장된 모든 시크릿 목록 보기)
action_list_all() {
  echo -e "\n${COLOR_BOLD}=== All Secrets in BWS ===${COLOR_RESET}"
  local secrets_json
  secrets_json=$(get_all_secrets_json)

  python3 -c '
import sys, json

secrets_json = sys.argv[1]
curr_key = sys.argv[2]
secrets = json.loads(secrets_json)

if not secrets:
    print("\033[33m저장된 시크릿이 없습니다.\033[0m\n")
    sys.exit(0)

h_k, h_l, h_b, h_c = "KEY", "LINES", "BYTES", "CURRENT"
print(f"  \033[1m\033[36m{h_k:<35}  {h_l:<8}  {h_b:<10}  {h_c}\033[0m")
print(f"  \033[90m{chr(45)*35}  {chr(45)*8}  {chr(45)*10}  {chr(45)*8}\033[0m")

for s in sorted(secrets, key=lambda x: x.get("key", "")):
    k = s.get("key", "")
    val = s.get("value", "")
    l_cnt = len(val.splitlines())
    b_len = len(val.encode("utf-8"))
    tag = "\033[32m[Active]\033[0m" if k == curr_key else ""
    print(f"  {k:<35}  {l_cnt:<8}  {b_len:<10}  {tag}")
print()
' "$secrets_json" "$(get_current_key)"
}

# 10. Change Settings
action_change() {
  echo -e "\n${COLOR_BOLD}=== Change Target Settings ===${COLOR_RESET}"
  echo -e " 1) Service 접두사 변경 [현재: ${COLOR_CYAN}${SERVICE_NAME}${COLOR_RESET}]"
  echo -e " 2) Target 파일 경로 변경 [현재: ${COLOR_YELLOW}${ENV_FILE}${COLOR_RESET}]"
  echo " 0) 뒤로가기"
  read -r -p "선택하세요 [1-2, 0]: " c_opt

  case "$c_opt" in
    1)
      read -r -p "새 Service 접두사 입력 [기본값: ${CURRENT_DIR}]: " new_srv
      if [ -n "$new_srv" ]; then
        SERVICE_NAME="$new_srv"
        echo -e "${COLOR_GREEN}Service 접두사가 '${SERVICE_NAME}' 로 변경되었습니다.${COLOR_RESET}"
      fi
      ;;
    2)
      read -r -p "새 파일 경로 입력 [현재: ${ENV_FILE}]: " new_path
      if [ -n "$new_path" ]; then
        ENV_FILE="$new_path"
        echo -e "${COLOR_GREEN}Target 파일이 '${ENV_FILE}' 로 변경되었습니다.${COLOR_RESET}"
      fi
      ;;
    *)
      ;;
  esac
}

# 11. Token Settings
action_token() {
  echo -e "\n${COLOR_BOLD}=== BWS Access Token Settings ===${COLOR_RESET}"
  echo -e " 현재 토큰 소스: ${COLOR_CYAN}${TOKEN_SOURCE}${COLOR_RESET}"

  local masked_token="(없음)"
  if [ -n "$BWS_ACCESS_TOKEN" ]; then
    local t_len=${#BWS_ACCESS_TOKEN}
    if [ "$t_len" -le 8 ]; then
      masked_token="****"
    else
      masked_token="${BWS_ACCESS_TOKEN:0:4}****${BWS_ACCESS_TOKEN: -4}"
    fi
  fi
  echo -e " 현재 적용 토큰: ${COLOR_YELLOW}${masked_token}${COLOR_RESET}"
  echo -e " 저장 파일 경로: ${COLOR_GRAY}${TOKEN_FILE}${COLOR_RESET} $([ -f "$TOKEN_FILE" ] && echo -e "${COLOR_GREEN}(파일 존재)${COLOR_RESET}" || echo -e "${COLOR_GRAY}(미생성)${COLOR_RESET}")"
  echo ""
  echo " 1) 새 토큰 입력 및 저장"
  echo " 2) 저장된 토큰 파일 삭제"
  echo " 0) 뒤로가기"
  read -r -p "선택하세요 [1-2, 0]: " t_opt

  case "$t_opt" in
    1)
      read -r -p "새로운 Access Token 입력: " new_tok
      new_tok=$(echo "$new_tok" | tr -d '\r\n')
      if [ -n "$new_tok" ]; then
        export BWS_ACCESS_TOKEN="$new_tok"
        mkdir -p "$(dirname "$TOKEN_FILE")"
        echo "$new_tok" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
        TOKEN_SOURCE="설정 파일 ($TOKEN_FILE)"
        echo -e "${COLOR_GREEN}${COLOR_BOLD}성공:${COLOR_RESET} 새로운 토큰이 '$TOKEN_FILE'에 저장되었습니다 (권한: 600)."
      fi
      ;;
    2)
      if [ -f "$TOKEN_FILE" ]; then
        rm -f "$TOKEN_FILE"
        echo -e "${COLOR_YELLOW}저장된 토큰 파일이 삭제되었습니다.${COLOR_RESET}"
        TOKEN_SOURCE="현재 세션 (임시)"
      else
        echo "삭제할 토큰 파일이 없습니다."
      fi
      ;;
    *)
      ;;
  esac
}

# 메인 루프
main() {
  check_token
  ensure_internal_project_id

  while true; do
    local secret_key
    secret_key=$(get_current_key)

    local loc_status="${COLOR_RED}(파일 없음)${COLOR_RESET}"
    if [ -f "$ENV_FILE" ]; then
      local l_count
      l_count=$(wc -l < "$ENV_FILE" | tr -d ' ')
      loc_status="${COLOR_GREEN}(존재함: ${l_count}줄)${COLOR_RESET}"
    fi

    echo -e "\n========================================================"
    echo -e " ${COLOR_BOLD}Bitwarden Secrets .env Sync (${COLOR_CYAN}bws-env${COLOR_RESET}${COLOR_BOLD})${COLOR_RESET}"
    echo -e " ${COLOR_BOLD}Service:${COLOR_RESET}     ${COLOR_CYAN}${SERVICE_NAME}${COLOR_RESET}"
    echo -e " ${COLOR_BOLD}Target File:${COLOR_RESET} ${COLOR_YELLOW}${ENV_FILE}${COLOR_RESET}  ${loc_status}"
    echo -e " ${COLOR_BOLD}BWS Key:${COLOR_RESET}     ${COLOR_GREEN}${COLOR_BOLD}${secret_key}${COLOR_RESET}"
    echo -e "========================================================"
    echo " 1) pull     - BWS ➔ 로컬 파일 가져오기 (Pull 서브메뉴)"
    echo " 2) push     - 로컬 파일 ➔ BWS 서버 반영하기 (Push 서브메뉴)"
    echo " 3) diff     - 로컬 vs 원격 줄 단위 비교"
    echo " 4) view     - 원격 시크릿 내용 보기 (${secret_key})"
    echo " 5) list     - 저장된 모든 시크릿 목록 조회"
    echo " 6) change   - 대상 파일 또는 서비스 접두사 변경"
    echo " 7) token    - 토큰 관리 (확인 / 재설정 / 삭제)"
    echo " 0) exit     - 종료"
    echo "--------------------------------------------------------"
    read -r -p "선택하세요 [1-7, 0]: " opt

    case "$opt" in
      1|pull)
        submenu_pull
        ;;
      2|push)
        submenu_push
        ;;
      3|diff|d)
        echo ""
        render_diff "$ENV_FILE" "$secret_key" || true
        ;;
      4|view|v)
        echo ""
        action_view
        ;;
      5|list|l)
        action_list_all
        ;;
      6|change|c)
        action_change
        ;;
      7|token|t)
        action_token
        ;;
      0|exit|q)
        echo -e "${COLOR_GRAY}bws-env를 종료합니다.${COLOR_RESET}"
        exit 0
        ;;
      *)
        echo -e "${COLOR_RED}올바른 메뉴를 선택해 주세요.${COLOR_RESET}"
        ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
