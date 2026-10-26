/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      fontFamily: {
        // 고정폭(font-mono): 영문·숫자는 Consolas 등, 한글이 섞이면 굴림체 대신 Pretendard로 그린다.
        mono: [
          'ui-monospace',
          'SFMono-Regular',
          'Consolas',
          'Menlo',
          'Pretendard Variable',
          'Malgun Gothic',
          'monospace',
        ],
        sans: [
          'Pretendard Variable', // @font-face는 src/index.css (public/fonts/)
          'Pretendard',
          'Noto Sans KR',
          'Apple SD Gothic Neo',
          'Malgun Gothic',
          'sans-serif',
        ],
      },
      colors: {
        // UX1 명세서 2.2/2.3 — 새봄고 로고 기반 공식 색상 토큰.
        // 기존 sanmaeul-* 임시값을 대체한다. sanmaeul-*는 하위호환을 위해
        // brand.deepGreen과 동일 값으로 당분간 유지(점진적 마이그레이션).
        brand: {
          orange: '#F39800',
          orangeSoft: 'rgb(var(--c-orange-soft) / <alpha-value>)',
          // 2026-10-12: 글자색으로도 쓰여 흰 배경 대비 4.5:1을 맞추려 어둡게(#D97900 → #A35F00)
          orangeStrong: '#A35F00',
          // 2026-10-20: 주 색상(초록 계열)은 CSS 변수로 둔다 — 전편입학 모드에서는 파란 계열로 바뀐다
          // (src/index.css 의 [data-admission-mode='transfer'], src/lib/admissionMode.js).
          green: 'rgb(var(--theme-green-rgb) / <alpha-value>)',
          greenSoft: 'rgb(var(--theme-green-soft-rgb) / <alpha-value>)',
          // 2026-10-12: 흰 글씨 버튼 대비 4.5:1 충족을 위해 한 단계 어둡게(#009944 → #00873C).
          // 로고 이미지 색은 그대로다.
          deepGreen: 'rgb(var(--theme-deep-rgb) / <alpha-value>)',
          deepGreenStrong: 'rgb(var(--theme-deep-strong-rgb) / <alpha-value>)',
          blue: 'rgb(var(--c-blue) / <alpha-value>)',
          blueSoft: 'rgb(var(--c-blue-soft) / <alpha-value>)',
          yellow: '#FFE800',
          purple: '#9D3C85',
          brown: '#7C591A',
        },
        // 2026-10-26: 다크 모드 — 아래 값은 CSS 변수(src/index.css)로 둔다. 밝은 값은 예전과 같다.
        status: {
          danger: 'rgb(var(--c-danger) / <alpha-value>)', // 밝게 #C9362B
          dangerSoft: 'rgb(var(--c-danger-soft) / <alpha-value>)',
          warning: 'rgb(var(--c-warning) / <alpha-value>)', // 밝게 #9A5900 (대비 4.5:1)
          warningSoft: 'rgb(var(--c-warning-soft) / <alpha-value>)',
        },
        surface: {
          canvas: 'rgb(var(--c-canvas) / <alpha-value>)',
          card: 'rgb(var(--c-card) / <alpha-value>)',
          subtle: 'rgb(var(--c-subtle) / <alpha-value>)',
        },
        border: {
          DEFAULT: 'rgb(var(--c-border) / <alpha-value>)',
          strong: 'rgb(var(--c-border-strong) / <alpha-value>)',
        },
        ink: {
          primary: 'rgb(var(--c-ink) / <alpha-value>)',
          secondary: 'rgb(var(--c-ink-2) / <alpha-value>)',
          muted: 'rgb(var(--c-ink-3) / <alpha-value>)', // 밝게 #687169 (대비 4.5:1)
        },
        // 하위호환: 기존 페이지들이 sanmaeul-500/600/700 등을 이미 광범위하게
        // 쓰고 있어 한 번에 다 바꾸면 회귀 위험이 크다. UX1-C 이후 페이지를
        // 실제로 리빌드할 때 brand.deepGreen으로 점진 교체한다.
        sanmaeul: {
          50: 'rgb(var(--theme-green-soft-rgb) / <alpha-value>)',
          100: 'rgb(var(--theme-green-soft-rgb) / <alpha-value>)',
          500: 'rgb(var(--theme-green-rgb) / <alpha-value>)',
          600: 'rgb(var(--theme-deep-rgb) / <alpha-value>)',
          700: 'rgb(var(--theme-deep-strong-rgb) / <alpha-value>)',
        },
      },
      borderRadius: {
        card: '12px',
        dialog: '16px',
      },
      boxShadow: {
        card: '0 1px 2px rgba(28, 40, 31, 0.04)',
      },
    },
  },
  plugins: [],
}
