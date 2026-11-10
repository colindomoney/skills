// Load Cloudflare Turnstile only when a visitor starts using a form, so
// people who only read the page send nothing to Cloudflare. Turnstile
// renders every `.cf-turnstile` element itself once its script loads.
const TURNSTILE_SRC = "https://challenges.cloudflare.com/turnstile/v0/api.js";
const TOKEN_FIELD = '[name="cf-turnstile-response"]';

function loadTurnstile() {
  if (document.querySelector("script[data-turnstile]")) return;
  const script = document.createElement("script");
  script.src = TURNSTILE_SRC;
  script.async = true;
  script.dataset.turnstile = "";
  document.head.append(script);
}

export function loadTurnstileOnInteraction(form: HTMLFormElement | null) {
  form?.addEventListener("focusin", loadTurnstile, { once: true });
}

// Because Turnstile now starts on first focus, a fast visitor can submit
// before it has issued a token. Wait for one (up to timeoutMs) rather than
// failing straight away. Returns "" if none arrives in time.
export async function waitForTurnstileToken(form: HTMLFormElement, timeoutMs = 10000): Promise<string> {
  loadTurnstile();
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const token = (form.querySelector(TOKEN_FIELD) as HTMLInputElement | null)?.value ?? "";
    if (token || Date.now() >= deadline) return token;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
}
