# 설치 안내서

이 문서를 위에서부터 차례로 따라 하면 됩니다. 처음 한 번 1~3시간쯤 걸립니다.
AI 코딩 도구(Claude Code 등)에 "INSTALL.md대로 설치를 도와줘"라고 해도 됩니다.

준비물: 컴퓨터 1대(Windows/macOS), [Node.js 20 이상](https://nodejs.org), [Git](https://git-scm.com), 학교 이름이 들어간 로고·직인 그림(선택)

---

## 0단계. 어디에 설치할지 정하기

| | Supabase 클라우드 | 학교 PC에 직접 설치(셀프 호스팅) |
|---|---|---|
| 난이도 | 쉬움 | 어려움(Docker 필요) |
| 개인정보 저장 위치 | 외부 서버(해외 리전 포함) | 학교 안 |
| 비용 | 무료 요금제로 시작 가능 | 무료(전기·PC만) |
| 주의 | 무료 요금제는 1주일 안 쓰면 일시 정지, 저장 용량 1GB, 파일 하나 50MB 제한 | PC가 꺼지면 접속 불가, 백업을 직접 해야 함 |

**지원자 개인정보를 어디에 둘지는 학교·교육청 개인정보 지침을 먼저 확인하세요.**
처음 시험해 볼 때는 클라우드로 설치해 보고, 실제 운영은 학교 판단에 따라 정하는 것을 권합니다.

- 클라우드: <https://supabase.com> 가입 → New project (리전은 Seoul 권장, DB 비밀번호는 따로 잘 보관)
- 셀프 호스팅: <https://supabase.com/docs/guides/self-hosting/docker> 를 따라 Docker로 설치

---

## 1단계. 코드 받기와 학교 이름 바꾸기

```bash
git clone <이 저장소 주소> admission-system
cd admission-system
npm ci
node scripts/set-school-name.mjs 한빛고등학교 한빛고 한빛
```

- `set-school-name.mjs`는 예시 학교 이름 `새봄고등학교 / 새봄고 / 새봄`을 우리 학교 이름으로 바꿉니다.
  DB 함수 안의 문자 문구도 바뀌므로 **2단계(install.sql) 전에** 돌리세요.
- 로고·직인: `src/assets/school-logo.png`(로고), `src/assets/schooi-seal.png`(직인, 배경 투명 PNG),
  `public/icons/`(앱 아이콘)를 우리 학교 그림으로 바꿉니다.
  **직인 그림은 공개 저장소에 올리지 마세요**(직접 바꾼 저장소를 공개할 경우).
- 수험표·접수증 아래 안내 문구와 일정: `src/config/printNotices.js`

## 2단계. 데이터베이스 만들기 (install.sql)

`supabase/install.sql` 하나에 표·권한(RLS)·DB 함수·파일 저장소 버킷이 모두 들어 있습니다. **딱 한 번** 실행합니다.

- 클라우드: 대시보드 > SQL Editor > New query 에 `install.sql` 전체를 붙여 넣고 Run (몇십 초)
  - 파일이 커서 붙여 넣기가 안 되면 `supabase/migrations/`의 파일을 번호 순서대로 하나씩 실행해도 결과는 같습니다.
- 셀프 호스팅:
  ```bash
  docker exec -i supabase-db psql -v ON_ERROR_STOP=1 -U postgres -d postgres < supabase/install.sql
  ```

끝나면 SQL Editor에서 `NOTIFY pgrst, 'reload schema';` 를 한 번 실행합니다(install.sql 끝에도 들어 있음).

> install.sql 안에는 개발 중에 만들었다가 뒤에서 지운 기능(사전 원서, 00023~00049)도 순서대로 들어 있습니다.
> 실행 결과에는 남지 않으니 신경 쓰지 않아도 됩니다. `pg_cron`, `pg_net` 확장을 켜는 줄이 있는데 Supabase에는 기본으로 들어 있습니다.

## 3단계. Edge Functions(서버 함수) 올리기와 비밀값 넣기

서버 함수는 문자 발송, 학교 검색, 교외 접속 문자 인증, 접수증 메일, 계정 관리를 맡습니다.

### 클라우드

```bash
npx supabase login
npx supabase init            # supabase/config.toml 이 생김(질문에는 기본값)
npx supabase link --project-ref <프로젝트 ID>   # 대시보드 주소 https://supabase.com/dashboard/project/<이 부분>
npx supabase functions deploy
```

비밀값(Secrets)은 대시보드 > Edge Functions > Secrets 에서 넣거나:

```bash
npx supabase secrets set MUNJANARA_USERID=... MUNJANARA_PASSWD=... SMS_SENDER_NUMBER=...
```

### 셀프 호스팅

`supabase/functions/` 안의 폴더들을 Supabase Docker 폴더의 `volumes/functions/` 로 복사하고,
`docker-compose.yml`의 `functions` 서비스 `environment:` 에 아래 비밀값을 넣은 뒤 `docker compose up -d functions`.

### 비밀값 목록 (모두 선택 — 없으면 그 기능만 꺼짐)

| 이름 | 쓰는 곳 | 비고 |
|---|---|---|
| `MUNJANARA_USERID`, `MUNJANARA_PASSWD`, `SMS_SENDER_NUMBER` | 모든 문자 | [문자나라](https://munjanara.co.kr) 웹연동. 비밀번호는 로그인 비밀번호가 아닌 '2차 비밀번호', 발신번호는 미리 등록한 번호(숫자만) |
| `NEIS_API_KEY` | 출신 중학교 검색 | [NEIS 교육정보 개방 포털](https://open.neis.go.kr)에서 무료 발급 |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM_NAME` | 접수증 메일 | Gmail이면 `smtp.gmail.com` / `465` / 앱 비밀번호 |

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`는 Supabase가 자동으로 넣어 줍니다.
**비밀값은 코드·게시물·채팅에 절대 적지 마세요.** 문자 서비스를 다른 업체로 바꾸려면 `supabase/functions/_shared/smsProvider.ts` 하나만 고치면 됩니다.

## 4단계. 인증(Authentication) 설정

대시보드 > Authentication 에서:

1. **Sign In / Providers > Email**: 켜 두고, **Allow new users to sign up은 끕니다**(계정은 관리자가 만들어 줌).
2. **URL Configuration > Site URL**: 5단계에서 정할 웹 주소를 넣습니다.
3. **Users > Add user**: 최고관리자가 쓸 이메일·비밀번호로 사용자 1명을 만듭니다(Auto Confirm User 켜기).

## 5단계. 첫 설정 SQL 실행 (supabase/setup/)

SQL Editor에서 번호 순서대로 실행합니다. **실행 전에 파일 안의 값을 우리 학교 모집요강에 맞게 고치세요.**

| 파일 | 하는 일 | 고칠 것 |
|---|---|---|
| `01_first-superadmin.sql` | 4단계에서 만든 사용자를 최고관리자로 | 이메일·이름·휴대전화·학년도 |
| `02_round-main.sql` | 학년도 주전형(main) 만들기 | 접수 기간·서류평가·심층평가·발표 날짜 |
| `03_scoring-quantitative.sql` | 출결·학업·공동체 배점 | 배점·감점 기준 |
| `04_scoring-essay-opinion.sql` | 자기소개서·학부모 소견서 배점 | 항목·배점 |
| `05_quota-bonus.sql` | 모집 인원·전형별 정원·가산점·동점 기준 | 모집 인원, 배수, 가산 비율 |
| `06_unfilled-track-policy.sql` | 특별전형 미충원 인원 처리 | 이월 여부 |
| `07_deep-group.sql` ~ `10_deep-document-carry.sql` | 2단계 심층역량평가(모둠·면접·글쓰기, 1단계 점수 반영 비율) | 영역·배점·반영 비율 |

- 예시는 **2027학년도(year = 2027)** 기준입니다. 다른 학년도라면 파일 안의 `2027`을 모두 바꿉니다.
- 설정은 '바꿀 수 없는 판(revision)'으로 쌓입니다. 나중에 바꾸려면 파일을 고쳐 다시 실행하면 새 판이 만들어집니다.
- 우리 학교 전형에 없는 단계(예: 모둠활동)는 그 파일을 실행하지 않아도 됩니다. 단, 화면에서 해당 메뉴가 비어 보일 수 있습니다.

## 6단계. 채점기준표 넣기 (선택, 대외비)

서류평가 정성 영역(자기소개서·소견서·공동체)의 채점기준표는 **코드에 넣지 않고 DB에만** 둡니다.
권한 있는 위원에게만 화면에 보입니다. 아래처럼 SQL로 넣고, **이 SQL 파일은 git에 올리지 마세요**
(`supabase/private/` 폴더는 .gitignore 에 들어 있습니다).

```sql
insert into public.evaluation_rubrics (year, area, content) values
(2027, 'essay', '{
  "notice": "대외비 — 무단 복사·반출 금지",
  "levelLabels": ["매우 우수", "우수", "보통", "미흡", "매우 미흡"],
  "criteria": [
    { "key": "항목key", "label": "항목 이름", "hint": "보는 점",
      "levels": [ { "score": 20, "text": "…" }, { "score": 16, "text": "…" } ] }
  ]
}'::jsonb)
on conflict (year, area) do update set content = excluded.content, updated_at = now();
```

- `area`: `common`(공통 원칙) / `essay` / `opinion` / `community`
- `criteria[].key`는 5단계 배점 설정(`03`·`04` 파일)의 항목 key와 같아야 점수 고르기 칸과 이어집니다.

## 7단계. 웹 화면 올리기

```bash
cp .env.example .env.production
# .env.production 에 VITE_SUPABASE_URL, VITE_SUPABASE_ANON_KEY 입력 (대시보드 > Project Settings > API)
npm run build      # dist/ 폴더가 생김
```

- **Vercel(무료)**: 저장소를 연결하고 환경변수 두 개를 넣으면 끝(`vercel.json`이 들어 있음).
- **Netlify 등**: `dist/` 를 올리고, 모든 경로를 `index.html`로 보내는 설정을 켭니다.
- **셀프 호스팅**: `dist/` 를 Caddy·Nginx 같은 웹 서버로 내보냅니다(https 필수 — 카메라·복사 기능이 https에서만 동작).

접속해서 4단계의 이메일로 로그인하면 됩니다. 그다음 계정은 **[계정 관리]** 화면에서 만듭니다.

## 8단계. (선택) 교외 접속 휴대폰 인증

학교 밖에서 접속하는 교직원에게 문자 인증을 한 번 더 받는 기능입니다.
**Cloudflare 터널을 거쳐 접속하는 구성에서만 동작합니다**(접속 IP를 `Cf-Connecting-Ip` 헤더로 판단).

1. 학교 공인 IP를 등록합니다(예시 값 `203.0.113.10/32`를 바꿈):
   ```sql
   delete from public.trusted_networks where cidr = '203.0.113.10/32';
   insert into public.trusted_networks (cidr, label) values ('<우리 학교 공인 IP>/32', '학교 공인 IP');
   ```
2. 교직원 계정마다 휴대전화를 넣어 둡니다(계정 관리 화면).
3. 문자 비밀값(3단계)이 있어야 인증번호가 갑니다.

## 업데이트

새 판이 나오면 `supabase/migrations/`에 **새로 생긴 파일만** 번호 순서대로 실행하고, 서버 함수를 다시 올리고, 화면을 다시 빌드합니다.
운영 중에는 반드시 먼저 백업하세요(클라우드: 대시보드 > Database > Backups / 셀프 호스팅: `pg_dump`).

## 교직원 투표 (선택)

머리글 아래에 투표 띠를 띄울 수 있습니다. SQL로 한 줄 넣으면 열립니다.

```sql
insert into public.staff_polls (id, title, description, options, closes_at) values (
  'poll-1', '회의 날짜 정하기', '마음에 드는 날을 골라 주세요.',
  '[{"key":"A","label":"월요일","desc":""},{"key":"B","label":"화요일","desc":""}]'::jsonb,
  '2026-12-01 18:00:00+09');
```

## 막힐 때

- 화면이 하얗게 나오면: 브라우저 개발자 도구(F12) > Console 의 빨간 글씨를 확인하세요. 대부분 `.env.production` 값 문제입니다.
- "함수가 없습니다"류 오류: SQL Editor에서 `NOTIFY pgrst, 'reload schema';`
- 문자가 안 가면: Edge Functions > Logs 에서 해당 함수 기록을 보세요.
- 그 밖에는 저장소 이슈로 알려 주세요.
