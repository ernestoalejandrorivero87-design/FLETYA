# Comisión en efectivo en FLETYA Piloto

## Antes de la actualización

- Verifica el banco, el nombre exacto del beneficiario y la CLABE contra los datos de la cuenta de FLETYA. Los datos se configuran en `private.cash_commission_spei_account` en Supabase Piloto.
- Firma Fletero Piloto 0.5.14 con el certificado que usan las instalaciones actuales. Coordina la actualización de todos los fleteros del piloto y el despliegue de Admin.
- Revisa los servicios en efectivo completados que aún tienen `cash_collected_at` vacío. Si hay operaciones anteriores con cobro confirmado, concílialas en el flujo anterior antes de cambiar de versión. La actualización conserva los registros históricos.

## Despliegue

1. Verifica que el proyecto Piloto ya tenga los campos y funciones de efectivo del script `activate-cash-payments.sql`.
2. En la ventana coordinada de actualización aplica `activate-weekly-cash-commission.sql` y luego `activate-cash-commission-spei.sql` en Piloto. El nuevo cierre de efectivo requiere Fletero 0.5.14 o el panel web de Fletero actualizado.
3. Verifica que la fila única de `private.cash_commission_spei_account` contenga los datos bancarios aprobados. La cuenta se puede preparar antes de activar los cortes.
4. Despliega Admin y actualiza Fletero en los dispositivos del piloto.

La referencia SPEI se asigna por fletero y semana. Verifica el abono bancario por referencia e importe antes de registrar el corte. El corte usa horario de Cancún. Cierra el domingo y vence el martes siguiente.
