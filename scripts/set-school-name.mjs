// 예시 학교 이름('새봄고등학교')을 우리 학교 이름으로 한꺼번에 바꾼다.
//
//   node scripts/set-school-name.mjs 한빛고등학교 한빛고 한빛
//                                    └ 정식 이름     └ 줄임  └ 아주 짧은 이름(문자 머리말 등)
//
// 화면·인쇄물·문자 문구·DB 함수 안의 문구가 함께 바뀐다.
// DB 함수 문구도 바뀌므로 supabase/install.sql 을 실행하기 "전에" 돌리는 것이 가장 간단하다.
// (이미 설치했다면 바뀐 migrations/ 파일 중 문구가 들어간 함수만 다시 실행하거나, 처음부터 다시 설치)
// 바뀐 뒤에는 git diff 로 한 번 훑어보세요.

import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import { join, extname } from 'node:path'

const [full, short, tiny] = process.argv.slice(2)
if (!full || !short || !tiny) {
  console.error('사용법: node scripts/set-school-name.mjs <정식 이름> <줄임> <아주 짧은 이름>')
  console.error('   예: node scripts/set-school-name.mjs 한빛고등학교 한빛고 한빛')
  process.exit(1)
}

const TARGETS = ['src', 'supabase', 'index.html', 'vite.config.js', 'package.json']
const TEXT = new Set(['.js', '.jsx', '.ts', '.tsx', '.sql', '.html', '.json', '.css', '.md', '.mjs'])
const PAIRS = [['새봄고등학교', full], ['새봄고', short], ['새봄', tiny]]

let changed = 0
function walk(p) {
  const st = statSync(p, { throwIfNoEntry: false })
  if (!st) return
  if (st.isDirectory()) {
    for (const name of readdirSync(p)) if (name !== 'node_modules') walk(join(p, name))
    return
  }
  if (!TEXT.has(extname(p))) return
  const src = readFileSync(p, 'utf8')
  let out = src
  for (const [a, b] of PAIRS) out = out.split(a).join(b)
  if (out !== src) { writeFileSync(p, out); changed++; console.log('  바꿈:', p) }
}
for (const t of TARGETS) walk(t)
console.log(`\n${changed}개 파일에서 '새봄고등학교 / 새봄고 / 새봄' → '${full} / ${short} / ${tiny}'`)
