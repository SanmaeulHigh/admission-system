// Firebase 초기화
// 마스터 스펙 v1.2 섹션 0.2: 리전 asia-northeast3(서울) 필수
// dev/prod는 별도 Firebase 프로젝트로 완전히 분리한다 (.env.local vs .env.production).
// 절대 통합생활관리시스템 등 타 시스템과 같은 Firebase 프로젝트를 공유하지 않는다.

import { initializeApp, getApps } from 'firebase/app'
import { getAuth, connectAuthEmulator } from 'firebase/auth'
import { getFirestore, connectFirestoreEmulator } from 'firebase/firestore'
import { getStorage, connectStorageEmulator } from 'firebase/storage'
import { getFunctions, connectFunctionsEmulator } from 'firebase/functions'
import { initializeAppCheck, ReCaptchaV3Provider } from 'firebase/app-check'

const firebaseConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  storageBucket: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
  appId: import.meta.env.VITE_FIREBASE_APP_ID,
}

// 필수 리전. Functions는 반드시 이 리전으로 배포/호출한다.
export const FUNCTIONS_REGION = 'asia-northeast3'

const app = getApps().length ? getApps()[0] : initializeApp(firebaseConfig)

export const auth = getAuth(app)
export const db = getFirestore(app)
export const storage = getStorage(app)
export const functions = getFunctions(app, FUNCTIONS_REGION)

// App Check: M8 공개 Function 보호용 (섹션 6.3).
// 주의(섹션 1.1 정합): reCAPTCHA는 분석/광고 SDK가 아닌 보안 목적 예외로,
// "외부 제3자 서비스 일절 미사용" 원칙의 유일한 예외로 문서화한다.
if (import.meta.env.VITE_RECAPTCHA_SITE_KEY) {
  initializeAppCheck(app, {
    provider: new ReCaptchaV3Provider(import.meta.env.VITE_RECAPTCHA_SITE_KEY),
    isTokenAutoRefreshEnabled: true,
  })
}

// 로컬 개발 시 Emulator 연결 (VITE_USE_EMULATORS=true)
if (import.meta.env.VITE_USE_EMULATORS === 'true') {
  connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true })
  connectFirestoreEmulator(db, '127.0.0.1', 8080)
  connectStorageEmulator(storage, '127.0.0.1', 9199)
  connectFunctionsEmulator(functions, '127.0.0.1', 5001)
  // eslint-disable-next-line no-console
  console.info('[firebase] Emulator 모드로 연결됨')
}

export default app
