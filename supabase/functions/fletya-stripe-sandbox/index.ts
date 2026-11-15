const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
const sandboxProject = "https://ccdtpwvalqznasstnqxj.supabase.co";
const returnPage = sandboxProject + "/functions/v1/fletya-stripe-sandbox";
const testSession = /^cs_test_[A-Za-z0-9]+$/;

function json(data: unknown, status = 200) {
  return Response.json(data, { status, headers: { "Cache-Control": "no-store" } });
}

function checkoutUrl(value: unknown): string {
  // The URL comes from the authenticated Stripe API for a verified test
  // session. Stripe owns the URL format and may use a configured domain.
  if (typeof value !== "string" || !value.startsWith("https://")) {
    throw new Error("invalid_checkout_url");
  }
  const url = URL.parse(value);
  if (!url || url.protocol !== "https:" || !url.hostname || url.username || url.password) {
    throw new Error("invalid_checkout_url");
  }
  return url.href;
}

Deno.serve(async (request) => {
  if (request.method === "GET" && Deno.env.get("SUPABASE_URL") === sandboxProject) {
    return new Response(
      "FLETYA Cliente - Pruebas\n\nVuelve a la app y toca Consultar pago para comprobar el estado del pago de prueba.",
      { headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" } },
    );
  }
  if (request.method !== "POST") return json({ message: "Método no permitido." }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const stripeKey = Deno.env.get("STRIPE_TEST_SECRET_KEY");
  if (url !== sandboxProject || !serviceKey || !/^sk_test_[A-Za-z0-9]+$/.test(stripeKey ?? "")) {
    return json({ message: "El entorno de pagos de prueba aún no está configurado." }, 503);
  }
  const token = request.headers.get("Authorization");
  if (!token?.startsWith("Bearer ")) return json({ message: "Inicia sesión como cliente." }, 401);

  const db = async (action: string, client: string, params: Record<string, unknown> = {}) => {
    const response = await fetch(url + "/rest/v1/rpc/stripe_sandbox_order", {
      method: "POST", headers: { apikey: serviceKey, Authorization: "Bearer " + serviceKey, "Content-Type": "application/json" },
      body: JSON.stringify({ p_action: action, p_client: client, ...params }),
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) throw new Error("db_" + response.status);
    return await response.json();
  };

  const stripe = async (path: string, form?: Record<string, string>, id?: string) => {
    const headers = new Headers({ Authorization: "Bearer " + stripeKey });
    if (id) headers.set("Idempotency-Key", id);
    const response = await fetch("https://api.stripe.com/v1" + path, {
      method: form ? "POST" : "GET", headers, body: form ? new URLSearchParams(form) : undefined,
      redirect: "error", signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) {
      const error = (await response.json()).error;
      console.error("Stripe Sandbox", response.status, error?.code, error?.param, response.headers.get("request-id"));
      throw new Error("stripe_failure");
    }
    const data = await response.json();
    if (data.livemode !== false) throw new Error("live_object");
    return data;
  };

  try {
    const auth = await fetch(url + "/auth/v1/user", {
      headers: { apikey: serviceKey, Authorization: token }, signal: AbortSignal.timeout(8000),
    });
    if (!auth.ok) return json({ message: "Inicia sesión como cliente." }, 401);
    const user = (await auth.json()).id;
    const body = await request.json().catch(() => null);
    if (!uuid.test(user) || !body || !["start", "status", "cancel"].includes(body.action)) {
      return json({ message: "Solicitud de pago inválida." }, 400);
    }
    let order = await db("current", user);
    if (body.action === "cancel" && !order?.stripe_session) {
      return json({ message: "Consulta el pago de nuevo para recuperar la sesión de Stripe." }, 409);
    }
    if (body.action === "start") {
      if (!uuid.test(body.id) || !uuid.test(body.quote) || !["card", "spei"].includes(body.method)) {
        return json({ message: "Revisa la cotización y el método de pago." }, 400);
      }
      if (order && order.id !== body.id) {
        return json({ message: "Ya tienes un pago en curso. Revisa su estado." }, 409);
      }
      try {
        order = await db("reserve", user, {
          p_id: body.id, p_quote: body.quote, p_vehicle: body.vehicle, p_helpers: body.helpers,
          p_service: body.service, p_amount: body.amount, p_method: body.method,
        });
      } catch (error) {
        if (error instanceof Error && /db_(400|409)/.test(error.message)) {
          return json({ message: "Revisa el precio, la vigencia de la cotización y tus servicios activos." }, 409);
        }
        throw error;
      }
    }
    if (!order || order.state === "expired") return json({ state: "none" });
    if (order.state !== "pending") return json({ state: order.state, method: order.method, amount: order.amount });

    const cents = Math.round(Number(order.amount) * 100);
    const expires = Math.floor(Date.parse(order.expires_at) / 1000);
    let session;
    if (order.stripe_session) {
      if (!testSession.test(order.stripe_session)) throw new Error("invalid_session");
      session = await stripe("/checkout/sessions/" + order.stripe_session);
    } else {
      if (expires <= Date.now() / 1000) {
        await db("expire", user, { p_id: order.id });
        return json({ state: "none" });
      }
      // Replaying the same parameters also recovers a session created before a network interruption.
      const fields: Record<string, string> = {
        mode: "payment", currency: "mxn", client_reference_id: order.id,
        success_url: returnPage, cancel_url: returnPage, expires_at: String(expires),
        "line_items[0][price_data][currency]": "mxn",
        "line_items[0][price_data][product_data][name]": "Flete FLETYA de prueba",
        "line_items[0][price_data][unit_amount]": String(cents), "line_items[0][quantity]": "1",
        "adaptive_pricing[enabled]": "false",
        "allowed_payment_method_types[]": order.method === "spei" ? "customer_balance" : "card",
      };
      if (order.method === "spei") {
        const customer = await stripe("/customers", { description: "FLETYA prueba " + order.id }, "fletya-customer-" + order.id);
        fields.customer = customer.id;
        fields["payment_method_options[customer_balance][funding_type]"] = "bank_transfer";
        fields["payment_method_options[customer_balance][bank_transfer][type]"] = "mx_bank_transfer";
      }
      session = await stripe("/checkout/sessions", fields, "fletya-checkout-" + order.id);
    }
    if (!testSession.test(session.id) || (order.stripe_session && session.id !== order.stripe_session)
      || session.client_reference_id !== order.id || session.amount_total !== cents
      || session.currency !== "mxn" || session.mode !== "payment") throw new Error("session_mismatch");
    if (!order.stripe_session) {
      await db("attach", user, { p_id: order.id, p_session: session.id });
    }
    if (session.payment_status === "paid" && session.status === "complete") {
      const booked = await db("book", user, { p_id: order.id, p_session: session.id });
      return json({ state: booked.state, method: order.method, amount: order.amount });
    }
    if (body.action === "cancel" && session.status === "open") {
      try {
        session = await stripe("/checkout/sessions/" + session.id + "/expire", {}, "fletya-expire-" + order.id);
      } catch {
        return json({ message: "El pago cambió en Stripe. Consulta su estado de nuevo." }, 409);
      }
      if (session.id !== order.stripe_session || session.status !== "expired") throw new Error("session_mismatch");
    }
    if (session.status === "expired") {
      await db("expire", user, { p_id: order.id, p_session: session.id });
      return json({ state: "none" });
    }
    return json({ state: "pending", method: order.method, amount: order.amount,
      url: session.status === "open" ? checkoutUrl(session.url) : null });
  } catch (error) {
    console.error("FLETYA Stripe Sandbox", error instanceof Error && /^[a-z_0-9]+$/.test(error.message) ? error.message : "request_failed");
    return json({ message: "No se pudo consultar el pago de prueba. Vuelve a intentarlo." }, 502);
  }
});
