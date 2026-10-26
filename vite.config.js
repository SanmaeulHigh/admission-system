import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'

// 버전 표시(2026-10-26): package.json 의 version + 빌드한 날짜·커밋. 규칙은 docs/버전_규칙.md
const APP_VERSION = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf-8')).version
function gitShort() {
  try { return execSync('git rev-parse --short HEAD', { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim() } catch { return '' }
}

// 새봄고 입학전형 PWA
// 마스터 스펙 v1.2 섹션 0.2 / 1.3 참조
// 주의: 심층평가 최소 데이터 오프라인 캐시 원칙(섹션 1.3)에 따라
// runtimeCaching은 정적 자산에 한정한다. Supabase API(REST/Auth/Storage/
// Realtime) 응답은 SW 캐시 대상에서 명시적으로 제외한다 (denylist).
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')

  return {
    plugins: [
      react(),
      VitePWA({
        registerType: 'prompt',
        includeAssets: ['favicon.ico', 'favicon-32.png', 'apple-touch-icon.png'],
        manifest: {
          name: '새봄고 입학전형 시스템',
          short_name: '새봄 입학',
          description: '새봄고등학교 신입생 입학전형 통합관리시스템',
          theme_color: '#3c6533',
          background_color: '#ffffff',
          display: 'standalone',
          start_url: '/',
          icons: [
            { src: 'icons/icon-192.png', sizes: '192x192', type: 'image/png' },
            { src: 'icons/icon-512.png', sizes: '512x512', type: 'image/png' },
            { src: 'icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
          ],
        },
        workbox: {
          // 정적 자산(JS/CSS/폰트/아이콘)만 precache 대상.
          globPatterns: ['**/*.{js,css,html,svg,png,ico,woff2}'],
          // Supabase REST/Auth/Storage/Realtime 요청은 절대 런타임 캐시하지
          // 않는다 (섹션 1.1, 1.3 개인정보/오프라인 원칙).
          navigateFallbackDenylist: [/^\/__/, /supabase\.co/, /supabase\.in/, /127\.0\.0\.1:54321/],
          runtimeCaching: [],
        },
        devOptions: {
          enabled: false,
        },
      }),
    ],
    define: {
      __APP_VERSION__: JSON.stringify(APP_VERSION),
      __APP_BUILD__: JSON.stringify({ commit: gitShort(), builtAt: new Date().toISOString() }),
    },
    server: {
      port: 5173,
    },
  }
})
