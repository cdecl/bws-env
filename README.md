# bws-env

> **Bitwarden Secrets Manager(BWS)** 기반의 대화형 `.env` 파일 관리 및 동기화 도구

`bws-env`는 로컬 개발 환경의 `.env` 파일들을 **Bitwarden Secrets Manager(BWS)**에 안전하게 보관하고, 여러 머신이나 팀원 간에 빠르고 일관되게 동기화할 수 있도록 돕는 CLI 도구입니다.

---

## ✨ 왜 bws-env인가?

1. **파일 원문 100% 완전 보존 (Whole-File Sync)**
   - 개별 키-값 파싱 방식 대신 파일 전체 내용을 통째로 저장하므로, 주석(`#`), 섹션 구분을 위한 빈 줄, 따옴표 스타일, 멀티라인 값(SSL 인증서, PEM 개인키 등)이 전혀 훼손되지 않습니다.
2. **Git 스타일의 직관적인 워크플로우 (`pull` / `push` / `diff`)**
   - 개발자에게 가장 친숙한 Git 용어와 인터페이스를 채택했습니다.
   - 서버 반영(`push`)이나 로컬 다운로드(`pull`) 전, 줄 단위 컬러 Unified Diff를 먼저 확인하고 엔터 한 번으로 즉시 실행됩니다.
3. **BWS 무료 플랜의 '프로젝트 3개 제한' 영구 우회**
   - BWS에 매번 프로젝트를 새로 만들지 않고, **`폴더명/파일명` (예: `shynote/.env`) 접두사 키 방식**의 Flat Key-Value 구조로 동작합니다.
   - 단 1개의 BWS 프로젝트 안에서 수십~수백 개의 서비스 환경 파일을 제한 없이 관리할 수 있습니다.
4. **초고속 API 처리 (단 1회 호출)**
   - 수십 개의 환경 변수가 있어도 단 1번의 API 호출로 1초 미만에 저장 및 복원이 완료됩니다.
5. **안전한 자동 백업**
   - 원격 시크릿을 로컬 파일로 내려받을 때(`pull`), 기존 파일이 존재하면 자동으로 타임스탬프 백업(`.env.<timestamp>.bak`)을 생성하여 실수를 방지합니다.
6. **편리한 영구 토큰 자동 로드**
   - 터미널을 새로 열 때마다 `export BWS_ACCESS_TOKEN`을 입력할 필요 없이, 최초 1회 입력 시 `~/.config/bws/token`에 안전하게(권한 `600`) 저장되어 자동 로드됩니다.

---

## 📋 요구 사항 (Prerequisites)

- **OS**: macOS / Linux
- **필수 도구**:
  - [Bitwarden Secrets Manager CLI (`bws`)](https://bitwarden.com/help/secrets-manager-cli/) (v1.0.0+)
  - `jq`
  - `python3` (macOS/Linux 기본 탑재)

```bash
# Bitwarden Secrets Manager CLI (bws) 설치
curl https://bws.bitwarden.com/install | sh

# macOS (Homebrew) - jq 설치
brew install jq
```

---

## 🚀 빠른 시작 (Installation)

### 1. 스크립트 설치 및 PATH 등록
```bash
# 실행 권한 부여
chmod +x bws-env.sh

# 사용자 PATH에 복사 (예: ~/bin 또는 /usr/local/bin)
cp bws-env.sh ~/bin/bws-env
```

### 2. 실행
어떤 프로젝트 폴더에서든 바로 실행합니다:
```bash
cd ~/my-project
bws-env
```

*최초 실행 시 `BWS_ACCESS_TOKEN`이 설정되어 있지 않으면 대화형 프롬프트가 나타나며, 토큰을 입력하면 `~/.config/bws/token`에 안전하게 저장됩니다.*

---

## 🖥️ 화면 및 메뉴 구성

```text
========================================================
 Bitwarden Secrets .env Sync (bws-env)
 Service:     shynote
 Target File: ./.env  (존재함: 15줄)
 BWS Key:     shynote/.env
========================================================
 1) pull     - BWS ➔ 로컬 파일 가져오기 (Pull 서브메뉴)
 2) push     - 로컬 파일 ➔ BWS 서버 반영하기 (Push 서브메뉴)
 3) diff     - 로컬 vs 원격 줄 단위 비교
 4) view     - 원격 시크릿 내용 보기 (shynote/.env)
 5) list     - 저장된 모든 시크릿 목록 조회
 6) change   - 대상 파일 또는 서비스 접두사 변경
 7) token    - 토큰 관리 (확인 / 재설정 / 삭제)
 0) exit     - 종료
--------------------------------------------------------
선택하세요 [1-7, 0]: 
```

### 서브메뉴 동작 예시

#### `push` (로컬 ➔ BWS 서버)
로컬 `.env` 파일의 변경점을 BWS에 업로드합니다:
```text
=== Push: Local File ➔ Remote BWS ===
• Service Name : shynote
• Target File  : ./.env (존재함: 15줄)
• BWS Key      : shynote/.env
--------------------------------------------------------
=== Diff: Local [./.env] vs Remote BWS [shynote/.env] ===
상태: [MODIFIED] 로컬과 원격 시크릿의 내용이 다릅니다.

--- Remote BWS (shynote/.env)
+++ Local (./.env)
@@ -1,3 +1,4 @@
 # Server Config
-PORT=3000
+PORT=8080
 API_KEY=sk-xxxx

작업을 선택하세요:
 1) 지금 바로 BWS에 반영 (Push - 수정(Edit))
 2) 대상 파일/키 변경
 0) 취소 (메인 메뉴로 돌아가기)
--------------------------------------------------------
선택하세요 [default: 1]: <엔터 시 즉시 반영 완료>
```

#### `pull` (BWS 서버 ➔ 로컬)
원격 BWS 시크릿을 로컬 파일로 내려받습니다:
- 로컬 파일 덮어쓰기 전 자동으로 백업 파일(`.env.<timestamp>.bak`) 생성

---

## 🗂️ 다중 환경 파일 관리 (`change`)

`6) change` 메뉴를 사용하여 대상 파일 또는 서비스명을 변경할 수 있습니다:
- 기본 `.env` ➔ **`shynote/.env`**
- `.env.local` ➔ **`shynote/.env.local`**
- `.env.production` ➔ **`shynote/.env.production`**

한 저장소 안에서 여러 단계의 환경 세트를 깔끔하게 구분하여 관리할 수 있습니다.

---

## 🔒 보안 및 권한 안내

- 토큰 영구 저장 파일 `~/.config/bws/token`은 파일 생성 시 자동으로 **`chmod 600` (소유자만 읽기/쓰기 가능)** 권한이 부여됩니다.
- 민감 정보가 포함될 수 있는 토큰은 메뉴 내 마스킹(`0.uK****==`) 처리되어 노출되지 않습니다.

---

## 📄 라이선스

MIT License
