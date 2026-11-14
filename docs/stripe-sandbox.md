# Pagos de prueba en FLETYA Cliente

El flujo está disponible en la variante Android **Pruebas**, que usa el proyecto Supabase `ccdtpwvalqznasstnqxj`. La función `fletya-stripe-sandbox` valida la sesión de FLETYA y usa una clave secreta de Stripe de prueba guardada en el servidor.

## Configuración

En el panel de Supabase del proyecto **Pruebas**, abre **Edge Functions → Secrets** y guarda `STRIPE_TEST_SECRET_KEY` con la clave `sk_test_` del entorno de prueba de FLETYA en Stripe. No copies la clave al código, a la APK ni a un chat. En ese entorno de Stripe verifica que el método de transferencia bancaria esté habilitado si SPEI no aparece.

## Prueba en Android

1. En **FLETYA Cliente · Pruebas**, inicia sesión con una cuenta cliente de ese entorno y cotiza un flete.
2. Abre **Pagar con tarjeta de prueba**. En Stripe usa `4242 4242 4242 4242`, una fecha futura y un CVC de tres dígitos. Vuelve a la app y comprueba **Pago confirmado**. Comprueba **Buscando fletero** y cierra esa solicitud de prueba antes de iniciar otra.
3. Abre **Pagar por SPEI de prueba** en una nueva cotización. Sigue el flujo de Stripe para generar las instrucciones. Regresa a la app y comprueba **Pago de prueba pendiente**. Simula el abono en el sandbox de Stripe con el cliente y el importe de esa sesión. Consulta el pago en la app y comprueba **Pago confirmado**.
4. En una sesión independiente, usa `4000 0000 0000 0002` para ver el rechazo. Comprueba que el pago siga pendiente y que la app permita cerrar una sesión de Stripe que siga abierta.

El servidor consulta Checkout al regresar a la app o al pulsar **Consultar pago**. Una transferencia puede quedar pendiente tras cerrar Checkout. El pedido se crea una sola vez después de verificar el estado pagado, el importe, la moneda y la sesión. Esta prueba no abarca reembolsos, liquidaciones a fleteros ni el procesamiento por webhook con la app cerrada.

- [Tarjetas de prueba de Stripe](https://docs.stripe.com/testing)
- [Simular una transferencia entrante](https://docs.stripe.com/api/cash_balance_transactions/fund_cash_balance)
