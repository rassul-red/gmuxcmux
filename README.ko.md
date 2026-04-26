<h1 align="center">gmuxcmux</h1>
<p align="center"><b><a href="https://github.com/manaflow-ai/cmux">cmux</a>의 GUI-first 포크 — 워크스페이스는 방이 되고, 터미널 패널은 떠도는 유령이 됩니다.</b></p>

<p align="center">
  <a href="README.md">English</a> | 한국어
</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/badge/upstream-manaflow--ai%2Fcmux-555?logo=github" alt="Upstream cmux" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue" alt="License" /></a>
</p>

---

## 왜 GUI-first 인가

cmux는 이미 훌륭한 터미널입니다. 세로 탭, 알림, 분할, 내장 브라우저, libghostty 기반 GPU 가속까지. 하지만 *수많은 에이전트*를 동시에 굴리는 순간, "지금 무슨 일이 벌어지고 있지?"의 답은 여전히 **탭의 벽 안에 있는 텍스트의 벽**입니다. 누가 나를 기다리고 있는지 알려면 탭 제목을 일일이 읽어야 합니다.

gmuxcmux는 그 전제를 뒤집습니다. 터미널 그리드가 더 이상 유일한 1차 surface가 아닙니다. 새로운 primary surface는 **살아 있는 세계**입니다. 모든 워크스페이스는 하나의 방이 되고, 모든 터미널 패널은 픽셀아트 유령이 됩니다. 읽지 않고 흘끗 봅니다. 한눈에, 누가 책상에서 일하고 있고 누가 바닥을 배회하고 있고 누가 막 끝냈는지 — 모든 워크스페이스에서 동시에 — 알 수 있습니다.

> **터미널-first가 묻는 것:** _이 패널 안에 뭐가 있지?_
>
> **GUI-first가 묻는 것:** _내 모든 작업을 통틀어 지금 무슨 일이 벌어지고 있지?_

둘 다 여전히 중요한 질문입니다. cmux는 첫 번째 질문에 아름답게 답합니다. gmuxcmux는 두 번째 질문에 답하는 차분하고 ambient한 surface를 더합니다 — 터미널을 빼앗지 않고서.

---

## 멘탈 모델

| cmux 개념                | gmuxcmux 표현                                                  |
|---|---|
| Workspace                 | 방 (720×480 pt 사무실 풍경)                                     |
| Terminal panel            | 그 방 안에 서 있는 유령 에이전트                                |
| Panel role (사용자 지정)  | 스프라이트 변형: Builder · Debugger · Orchestrator · Reviewer   |
| 셸이 명령을 실행 중       | 유령이 책상으로 걸어가 앉음                                     |
| 셸이 프롬프트에서 대기 중 | 유령이 바닥을 배회                                              |
| 알림 발생                 | 초록 halo + DONE 말풍선 + 차임                                  |

모든 상태는 cmux가 이미 가진 prompt-idle / command-running 감지기와 OSC 9/99/777 알림으로부터 파생됩니다. **새로운 셸 계측도, 에이전트 측 설정도 필요 없습니다.** cmux에서 정상적으로 잡히는 셸이라면, 여기서도 정상적으로 잡힙니다.

---

## 두 개의 GUI surface, 하나의 진실

gmuxcmux는 터미널을 대체하지 않습니다. 터미널 옆에 두 개의 GUI surface를 더할 뿐입니다.

1. **Agents Panel** — 우측 사이드바의 컴팩트 미니맵. 항상 사용 가능. 각 워크스페이스는 라벨 붙은 방, 각 패널은 클릭 가능한 에이전트 박스. 탭하면 해당 터미널로 포커스. Release 빌드에서 안전.
2. **Agents Canvas** — 게임 같은 풀 월드. 핀치 줌 (0.5×–2.5×), 두 손가락 팬, 유령들이 의자로 걸어갔다 돌아오고, halo가 pulse하고, 에이전트가 끝나면 Glass 차임이 울림. DEBUG 전용, **Debug → Enable Agents Canvas**로 토글.

두 surface 모두 터미널 그리드와 동일한 상태 피드를 읽습니다. 어디에도 별도의 "에이전트 상태"는 없습니다 — GUI는 단지 터미널을 움직이는 동일한 진실의 또 다른 렌더링일 뿐입니다.

---

## 아키텍처, 한 호흡으로

- **`AgentWorldStore`** 는 `@MainActor` 싱글톤으로, 모든 유령의 `(position, target, facingLeft, arrived)`를 룸-로컬 좌표로 소유합니다. 유일한 mutation 진입점은 `tick(now:drivers:)`.
- **30 fps `Timer.publish`** 가 `tick`을 구동합니다. 위치는 30 pt/s로 보간되고, 도착하면 스냅하며, 유휴일 때 4–8초마다 새로운 wander 타깃을 고릅니다.
- **Snapshot 경계**: `AgentsCanvasRoomView`와 `AgentAvatarView`는 `Equatable` value-snapshot 뷰입니다. `ObservableObject`를 절대 잡지 않습니다. cmux의 Sessions 패널과 워크스페이스 사이드바를 `LazyLayoutViewCache` thrashing으로부터 보호하는 것과 동일한 규칙입니다 — 업스트림 이슈 [manaflow-ai/cmux#2586](https://github.com/manaflow-ai/cmux/issues/2586) 참조.
- **애니메이션 레이어** 는 엄격히 분리됩니다. 월드 위치는 `tick`이 구동합니다. "살아 보임" (idle bob, walk jiggle, DONE 말풍선 타이밍)은 `TimelineView(.animation)`이 담당합니다. 상태 쓰기는 절대 view body 안에서 일어나지 않습니다.

스프라이트 시스템, 방 레이아웃, 워크 사이클, 월드 캔버스, 수동 테스트 플랜 등 전체 설계 노트는 [`cmux-gui.md`](./cmux-gui.md)에 있습니다.

---

## 빌드와 실행

```bash
./scripts/setup.sh                                  # 서브모듈 + GhosttyKit 초기화
./scripts/reload.sh --tag cmux-gui --launch         # DEBUG 앱 빌드 후 실행
```

그다음 실행된 앱에서: **Debug → Enable Agents Canvas**.

> 항상 `--tag` 를 붙이세요. 태그 없는 `xcodebuild` 나 `open cmux DEV.app` 은 공유 소켓과 번들 ID를 통해 다른 태그된 디버그 인스턴스와 충돌합니다.

---

## 상태

이 저장소는 개인 포크입니다. **서명된 DMG도, Homebrew tap도, 자동 업데이트도 없습니다.** 소스에서 직접 빌드하세요. Agents Canvas는 의도적으로 DEBUG 전용이고, Agents Panel은 Release에서도 안전합니다.

캔버스의 알려진 한계:

- 진짜 pathfinding 없음 — 의자에서 바닥으로 걷는 유령은 다른 책상을 그대로 통과합니다.
- 멀티프레임 워크 애니메이션 없음 — 걷기는 좌우 미러링 + 4 Hz 수직 jiggle로 가짜로 구현됩니다.
- 가구 레이아웃과 wander 영역은 하드코딩된 상수입니다.
- Role 할당은 에이전트 우클릭으로 패널마다 수동입니다.
- 패널별 셸 활동은 cmux의 기존 감지기에서 옵니다. 특정 셸이나 프롬프트에서 감지기가 어긋나면, 앉아야 할 에이전트가 배회합니다.

업스트림 cmux의 모든 기능은 그대로 동작합니다. 세로 탭, 분할, 알림, 내장 브라우저, SSH, Claude Code Teams — 전부 변경 없음. 업스트림 기능과 전체 키보드 단축키는 [업스트림 cmux README](https://github.com/manaflow-ai/cmux#readme)를 참고하세요.

---

## 크레딧

- 모든 것의 토대가 되는 업스트림 터미널: [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux).
- 포크 출처: [rassul-red/gmuxcmux](https://github.com/rassul-red/gmuxcmux).
- Agents Panel 컨셉: PR #1, [@dbekzhan](https://github.com/dbekzhan).
- 스프라이트 시스템, world store, Agents Canvas: 이 포크.

## 라이선스

GPL-3.0-or-later, 업스트림 cmux로부터 상속. [LICENSE](./LICENSE) 참조.
