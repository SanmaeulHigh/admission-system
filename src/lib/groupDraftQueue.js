import { supabase } from './supabase'

const PREFIX = 'sanmaeul:m5b:group-drafts:'

function storageKey(userId) {
  return `${PREFIX}${userId}`
}

function readQueue(userId) {
  if (!userId) return []
  try {
    const raw = localStorage.getItem(storageKey(userId))
    const parsed = raw ? JSON.parse(raw) : []
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

function writeQueue(userId, entries) {
  if (!userId) return false
  try {
    localStorage.setItem(storageKey(userId), JSON.stringify(entries))
    return true
  } catch {
    return false
  }
}

export function getQueuedGroupDrafts(userId) {
  return readQueue(userId)
}

export function queueGroupDraft(userId, payload) {
  const current = readQueue(userId)
  const withoutApplicant = current.filter((entry) => entry.applicantId !== payload.applicantId)
  const existing = current.find((entry) => entry.applicantId === payload.applicantId)

  if (existing && new Date(existing.clientUpdatedAt) > new Date(payload.clientUpdatedAt)) {
    return existing
  }

  const next = [...withoutApplicant, payload]
  writeQueue(userId, next)
  return payload
}

export function removeQueuedGroupDraft(userId, applicantId) {
  writeQueue(
    userId,
    readQueue(userId).filter((entry) => entry.applicantId !== applicantId)
  )
}

export async function flushGroupDraftQueue(userId) {
  const entries = readQueue(userId)
    .slice()
    .sort((a, b) => new Date(a.clientUpdatedAt) - new Date(b.clientUpdatedAt))

  const results = []
  for (const entry of entries) {
    const { data, error } = await supabase.rpc('save_group_score_draft', {
      p_applicant_id: entry.applicantId,
      p_observation_confirmed: entry.observationConfirmed,
      p_observed_segment_ids: entry.observedSegmentIds,
      p_items: entry.items,
      p_client_updated_at: entry.clientUpdatedAt,
    })

    if (error) {
      results.push({ applicantId: entry.applicantId, ok: false, error: error.message })
      continue
    }

    removeQueuedGroupDraft(userId, entry.applicantId)
    results.push({ applicantId: entry.applicantId, ok: true, accepted: data?.accepted !== false })
  }

  return results
}
