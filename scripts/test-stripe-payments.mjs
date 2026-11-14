import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

const currency = 'mxn';
const amount = 40000;

export async function runSandboxPayments(key, request = fetch, report = console.log) {
    if (!/^sk_test_[A-Za-z0-9]+$/.test(key ?? '')) {
        throw new Error('Define STRIPE_TEST_SECRET_KEY con una clave sk_test_ de tu entorno de prueba.');
    }

    const run = randomUUID();
    async function stripe(path, step, form, allowDecline = false) {
        const headers = {
            Authorization: 'Bearer ' + key,
        };
        if (form) headers['Idempotency-Key'] = run + '-' + step;
        const response = await request('https://api.stripe.com/v1' + path, {
            method: form ? 'POST' : 'GET',
            headers,
            body: form ? new URLSearchParams(form) : undefined,
            signal: AbortSignal.timeout(20000),
            redirect: 'error',
        });
        const result = await response.json();
        if (allowDecline && response.status === 402 && result.error?.code === 'card_declined') {
            return result.error.payment_intent;
        }
        if (!response.ok) {
            const error = result?.error ?? {};
            const requestId = response.headers.get('request-id');
            const details = [error.type, error.code, error.param, requestId]
                .filter(value => typeof value === 'string' && /^[a-zA-Z0-9_[\].-]{1,100}$/.test(value)
                    && !/^(?:sk|rk|pk)_(?:test|live)_/.test(value));
            const message = typeof error.message === 'string'
                ? error.message.replaceAll(key, '[clave oculta]')
                    .replace(/\b(?:sk|rk|pk)_(?:test|live)_[\w.-]+/g, '[clave oculta]')
                    .replace(/[\x00-\x1f\x7f]/g, ' ').slice(0, 300)
                : '';
            throw new Error(step + ': Stripe respondió HTTP ' + response.status
                + (details.length ? ' (' + details.join(', ') + ')' : '')
                + (message ? ' · ' + message : ''));
        }
        if (result.livemode !== false) throw new Error(step + ': Stripe no confirmó el modo de prueba.');
        return result;
    }

    function verify(intent, status, received) {
        if (intent?.livemode !== false || intent.status !== status || intent.currency !== currency
            || intent.amount !== amount || intent.amount_received !== received
            || !/^pi_[A-Za-z0-9]+$/.test(intent.id)) {
            throw new Error('El estado, importe o moneda del pago no coincide con lo esperado (' + status + ').');
        }
    }

    const payment = { amount: String(amount), currency, confirm: 'true' };
    const card = await stripe('/payment_intents', 'tarjeta-aprobada', {
        ...payment, 'allowed_payment_method_types[]': 'card', return_url: 'https://fletya.vercel.app/', payment_method: 'pm_card_visa',
    });
    verify(card, 'succeeded', amount);
    report('Tarjeta de prueba aprobada · $400.00 MXN');

    const declined = await stripe('/payment_intents', 'tarjeta-rechazada', {
        ...payment, 'allowed_payment_method_types[]': 'card', return_url: 'https://fletya.vercel.app/', payment_method: 'pm_card_chargeDeclined',
    }, true);
    verify(declined, 'requires_payment_method', 0);
    report('Tarjeta de prueba rechazada · $0.00 MXN cobrados');

    const customer = await stripe('/customers', 'cliente-de-prueba', { description: 'FLETYA · prueba SPEI ' + run });
    if (!/^cus_[A-Za-z0-9]+$/.test(customer.id)) throw new Error('Stripe no devolvió un cliente de prueba válido.');
    const transfer = await stripe('/payment_intents', 'transferencia-pendiente', {
        ...payment,
        customer: customer.id,
        'allowed_payment_method_types[]': 'customer_balance',
        'payment_method_data[type]': 'customer_balance',
        'payment_method_options[customer_balance][funding_type]': 'bank_transfer',
        'payment_method_options[customer_balance][bank_transfer][type]': 'mx_bank_transfer',
    });
    verify(transfer, 'requires_action', 0);
    if (transfer.next_action?.type !== 'display_bank_transfer_instructions') {
        throw new Error('Stripe no devolvió instrucciones de transferencia de prueba.');
    }
    report('Transferencia de prueba pendiente · $0.00 MXN recibidos');

    const funded = await stripe('/test_helpers/customers/' + customer.id + '/fund_cash_balance',
        'simular-transferencia', { amount: String(amount), currency });
    if (funded.type !== 'funded' || funded.currency !== currency || funded.net_amount !== amount) {
        throw new Error('Stripe no confirmó el abono simulado.');
    }

    // Stripe reconciles the incoming balance with the pending payment asynchronously.
    for (let attempt = 0; attempt < 8; attempt++) {
        const confirmed = await stripe('/payment_intents/' + transfer.id, 'consultar-transferencia');
        if (confirmed.id !== transfer.id) throw new Error('Stripe devolvió otro pago.');
        if (confirmed.status === 'succeeded') {
            verify(confirmed, 'succeeded', amount);
            report('Transferencia de prueba confirmada · $400.00 MXN');
            return;
        }
        if (!['requires_action', 'processing'].includes(confirmed.status)) {
            throw new Error('La transferencia terminó en un estado inesperado: ' + confirmed.status);
        }
        if (attempt < 7) await new Promise(resolve => setTimeout(resolve, 2000));
    }
    throw new Error('La transferencia sigue pendiente. Revisa el pago ' + transfer.id + ' en el sandbox de Stripe.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    try {
        await runSandboxPayments(process.env.STRIPE_TEST_SECRET_KEY);
    } catch (error) {
        console.error(error.message);
        process.exitCode = 1;
    }
}
