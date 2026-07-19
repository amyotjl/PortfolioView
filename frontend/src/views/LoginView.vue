<script setup lang="ts">
// Placeholder auth surface. The real vee-validate + zod form (posting to
// POST /api/v1/session) is implemented in issue #038; this view establishes the
// route, the AuthLayout, and the navigation contract it will build on.
</script>

<template>
  <div>
    <h1 class="text-lg font-semibold tracking-tight text-ink">Sign in</h1>
    <p class="mt-1 text-sm text-ink-muted">Welcome back.</p>

    <p class="mt-6 rounded-md border border-dashed border-line-strong p-4 text-sm text-ink-muted">
      The sign-in form lands in issue #038.
    </p>

    <p class="mt-6 text-sm text-ink-muted">
      Need an account?
      <RouterLink :to="{ name: 'register' }" class="font-medium text-accent hover:text-accent-hi">
        Register
      </RouterLink>
    </p>
  </div>
</template>
