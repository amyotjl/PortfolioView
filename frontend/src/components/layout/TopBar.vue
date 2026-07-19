<script setup lang="ts">
import { computed, shallowRef } from 'vue'
import { storeToRefs } from 'pinia'
import { useRouter } from 'vue-router'
import { useAuthStore } from '@/stores/auth'
import { apiDelete } from '@/api/client'
import PortfolioSwitcher from './PortfolioSwitcher.vue'
import ThemeToggle from '@/components/ThemeToggle.vue'

const router = useRouter()
const authStore = useAuthStore()
const { user } = storeToRefs(authStore)

const email = computed(() => user.value?.email_address ?? '')
const signingOut = shallowRef(false)

async function signOut(): Promise<void> {
  if (signingOut.value) return
  signingOut.value = true
  try {
    await apiDelete('/session')
  } catch {
    // Even if the request fails we still drop the local session below.
  } finally {
    authStore.clear()
    signingOut.value = false
    router.push({ name: 'login' })
  }
}
</script>

<template>
  <header
    class="flex h-14 items-center gap-4 border-b border-line bg-panel px-4"
  >
    <RouterLink
      :to="{ name: 'portfolios' }"
      class="flex items-center gap-2 font-semibold tracking-tight text-ink"
    >
      <span
        class="grid h-6 w-6 place-items-center rounded bg-accent text-[0.7rem] font-bold text-on-accent"
        aria-hidden="true"
      >
        PV
      </span>
      <span class="hidden sm:inline">PortfolioView</span>
    </RouterLink>

    <PortfolioSwitcher />

    <div class="ml-auto flex items-center gap-3">
      <ThemeToggle />
      <span
        v-if="email"
        class="hidden max-w-[16rem] truncate text-sm text-ink-muted md:inline"
        :title="email"
      >
        {{ email }}
      </span>
      <button
        v-if="email"
        type="button"
        class="rounded-md border border-line px-3 py-1.5 text-sm font-medium text-ink-muted transition-colors hover:bg-panel-hi hover:text-ink disabled:opacity-60"
        :disabled="signingOut"
        @click="signOut"
      >
        {{ signingOut ? 'Signing out…' : 'Sign out' }}
      </button>
    </div>
  </header>
</template>
