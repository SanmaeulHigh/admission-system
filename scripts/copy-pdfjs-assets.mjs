// pdf.js 보조 자료(한글 등 CJK 문자표·표준 글꼴)를 public/pdfjs 로 복사한다.
// npm run build / npm run dev 때 자동으로 먼저 실행된다. 결과물은 git에 올리지 않는다(.gitignore).
import { cpSync, existsSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const src = join(root, 'node_modules', 'pdfjs-dist')
const dest = join(root, 'public', 'pdfjs')

if (!existsSync(src)) {
  console.error('[pdfjs] node_modules/pdfjs-dist 가 없습니다. 먼저 npm install 을 실행하세요.')
  process.exit(1)
}
mkdirSync(dest, { recursive: true })
for (const dir of ['cmaps', 'standard_fonts']) {
  cpSync(join(src, dir), join(dest, dir), { recursive: true })
}
console.log('[pdfjs] cmaps·standard_fonts 복사 완료 → public/pdfjs')
