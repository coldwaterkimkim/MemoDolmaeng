# MemoDolmaeng

평소에는 화면에서 사라져 있다가 엣지에 포인터를 대면 메모 제목만 꺼내 보여주는 로컬 macOS 메모 앱입니다.

## 제품 흐름

- 활성 메모 인덱스는 기본적으로 오른쪽 중앙의 촘촘한 한 그룹에 붙습니다.
- 왼쪽, 오른쪽 또는 메뉴 막대 바로 아래 상단 엣지에 포인터를 0.18초 대면 해당 엣지의 인덱스만 나타납니다.
- 포인터가 핫존과 인덱스를 벗어나면 기본 0.35초 뒤 인덱스가 다시 숨습니다.
- 인덱스를 클릭하면 `PEEK`, 더블클릭하면 `ICE`로 열립니다.
- `PEEK`는 포인터가 인덱스와 메모를 모두 벗어나면 접히고, `ICE`는 인덱스가 숨더라도 유지됩니다.
- 한 번에 편집 패널 하나만 열립니다. ICE에서 다른 메모를 고르면 패널을 유지한 채 본문만 바뀝니다.
- `Esc`와 `Cmd+W`는 삭제가 아니라 접기입니다.
- 앱은 Dock 없이 메뉴 막대에 상주하며 모든 Space와 전체 화면 앱 위에서 접근할 수 있습니다.

## 그룹과 배치

- 활성 메모는 최대 10개, 보관 메모는 무제한입니다.
- 하나의 그룹 안에서는 간격 0px로 붙고, 서로 다른 그룹은 최소 6px를 둡니다.
- 인덱스를 기존 그룹 밖으로 끌면 단독 그룹이 되고, 다른 그룹 12px 안에 놓으면 해당 순서로 합쳐집니다.
- 드래그 중에는 왼쪽, 오른쪽, 상단 드롭 영역이 나타납니다.
- 상단 인덱스는 `NSScreen.visibleFrame.maxY` 아래에 붙고 메모는 아래 방향으로 열립니다.
- 작은 화면에서는 제목 원본과 툴팁은 유지한 채 인덱스 길이만 자동 압축합니다.
- 오래된 수동 그룹의 위치를 먼저 보존하고, 새 그룹과 기본 그룹이 남은 연속 공간에 맞춰 이동하거나 압축됩니다.
- 모니터가 사라지면 포인터가 있는 화면, 그다음 주 화면으로 복구됩니다.

## 메모 생명주기

- 새 메모는 빈 임시 초안으로 열리며 의미 있는 텍스트, 목록, 표, 코드 또는 이미지가 생긴 순간에만 저장됩니다.
- 빈 초안을 접으면 저장 파일에 흔적을 남기지 않습니다.
- 기존 메모를 완전히 비운 뒤 접기, 메모 전환, 보관 또는 앱 종료를 하면 본문과 첨부파일을 영구 삭제합니다.
- 보관은 되돌릴 수 있지만 보관함의 `삭제`는 확인 후 영구 삭제합니다. 휴지통과 자동 보관은 없습니다.
- 활성 메모 10개가 가득 차면 자동 보관하지 않고 보관함을 엽니다.

## Crepe 편집기

공유 `WKWebView` 안에서 `@milkdown/crepe`와 `@milkdown/kit` `7.21.2`를 사용합니다. Markdown 문자열은 저장 원본이지만 화면에서는 `**`, `~~`, 목록 기호를 직접 고치지 않고 Typora처럼 문서 노드를 편집합니다. 메모를 전환할 때 편집기를 다시 만들지 않고 Crepe 인스턴스 하나의 문서만 교체합니다.

- 텍스트 선택 시 나타나는 Crepe 서식 툴바
- `/` 블록 삽입 메뉴. 왼쪽 추가·드래그 핸들은 메모 여백을 위해 숨깁니다.
- 글머리표, 번호 목록, 체크리스트, 인용, 구분선
- 이미지 블록, 코드 블록, 표, 수식 블록과 링크 편집 UI
- 굵게, 기울임, 밑줄, 취소선, 글자색과 문단 정렬
- `Cmd+B/I/U`, 실행 취소/다시 실행, 목록 들여쓰기, 한글 조합 입력

별도 네이티브 하단 툴바는 두지 않습니다. 밑줄, 글자색, 정렬은 각각 `<u>`, 안전한 6자리 색상 `<span>`, 정렬 `<div>`로 Markdown에 왕복 저장합니다. 지원하지 않는 raw HTML은 텍스트형 보존 노드로 유지해 실행은 막고 원문은 지우지 않습니다. raw Markdown 모드와 AI 기능은 제공하지 않습니다.

이미지는 Crepe의 이미지 블록에서 선택합니다. Swift가 실제 이미지 여부와 20MB 제한을 확인한 뒤 `attachments/<note-id>/`로 복사하고, UUID와 단일 파일명만 허용하는 `memodolmaeng-asset://` 로더로 표시합니다.

## 단축키

- `Cmd+Shift+M`: 최근 메모 열기 또는 현재 메모 접기, 시스템 전역
- `Cmd+Shift+Up`, `Cmd+Shift+Down`: 열린 상태에서 이전 또는 다음 메모
- `Cmd+1`~`Cmd+0`: 열린 상태에서 1~10번 메모로 전환
- `Esc`, `Cmd+W`: 현재 메모 접기
- `Cmd+N`: 새 임시 메모

전역 단축키는 Carbon Hot Key API를 사용하므로 접근성 권한이 필요하지 않습니다.

## 로컬 저장과 v3 이전

```text
~/Library/Application Support/MemoDolmaeng/
├── notes.json
├── Backups/
├── attachments/<note-id>/
└── DeletionStaging/
```

```json
{
  "schemaVersion": 3,
  "notes": [],
  "edgeGroups": [],
  "defaultGroupID": "UUID"
}
```

v2를 처음 열 때 원본 바이트를 `Backups/notes-pre-edge-v3-<timestamp>.json`에 먼저 기록합니다. 내용이 있는 메모만 가져오고, 활성 메모는 기존 `handlePosition` 내림차순으로 정렬해 오른쪽 중앙 기본 그룹에 합칩니다. 백업, 변환 또는 v3 저장이 실패하면 v2 원본을 바꾸지 않고 앱 시작을 중단합니다.

첨부파일 영구 삭제는 디렉터리를 staging으로 이동한 뒤 메모 저장에 성공하면 물리 삭제합니다. 중간에 앱이 종료되면 다음 시작 때 메모 존재 여부에 따라 복구하거나 정리합니다.

## 구조

- `EdgeWorkspaceController`: 앱 상태, 초안/삭제 생명주기, 핫존, 드래그, PEEK/ICE
- `EdgeLayoutEngine`: 세 엣지 프레임, 그룹 압축, 충돌과 삽입 순서 계산
- `EdgeHotZoneController`, `EdgeHandlePanelController`: 숨김 핫존과 인덱스 패널
- `MemoPanelController`, `MarkdownEditorView`: 공유 패널과 Swift-Crepe 브리지
- `NoteStore`: v3 저장, v1/v2 백업 이전, 그룹 불변식과 활성 10개 제한
- `AttachmentService`, `MemoAssetSchemeHandler`: 이미지 복사, staged 삭제, 안전한 로딩
- `LibraryView`, `PreferencesView`: 검색 보관함과 공통/메모별 설정

## 실행과 검증

```bash
npm run build:editor
swift test
npm run test:editor
swift build
./script/build_and_run.sh --verify
```

격리 저장소 실행:

```bash
MEMODOLMAENG_DATA_DIR=/tmp/memodolmaeng-qa \
  ./dist/MemoDolmaeng.app/Contents/MacOS/MemoDolmaeng
```
