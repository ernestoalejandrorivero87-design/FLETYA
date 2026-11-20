# FLETYA — Hoja de ruta previa al lanzamiento
Actualización: 2026-11-19. Alcance inicial: Cancún.

## Orden acordado
1. Terminar integración financiera en Piloto: efectivo, comisión, cortes, SPEI, tarjetas, reembolsos, liquidaciones y reportes. Validar GPS y conciliación de operaciones anteriores. No activar tarjeta real sin revisar proveedor y condiciones.
2. Estudio de mercado local y diseño de fórmula rentable para fletero, competitiva para cliente y sostenible para FLETYA. No modificar tarifas hasta estudiar cotizaciones. Propuesta: configuración de tarifas desde Admin, versión de tarifa por cotización, precio confirmado inmutable.
3. Verificación obligatoria de fleteros antes del lanzamiento.
4. Retoques, pruebas integrales, revisión legal y operativa.
5. Lanzamiento local y publicidad.

## Verificación de fleteros
Requisitos solicitados: foto del fletero, licencia vigente, permiso de movilidad según vehículo, fotos de vehículo con placas. Propuestas adicionales: identificación oficial, tarjeta de circulación, seguro aplicable, fotos lateral y área de carga. Confirmar requisitos locales antes de determinar obligatoriedad por categoría.
- Registro con carga privada de documentos, estados pendiente/en revisión/aprobado/observado/rechazado/vencido.
- Admin revisa identidad, vigencia, coincidencia de placas y titularidad/autorización de uso. Consultar fuentes oficiales disponibles; no afirmar validación oficial cuando solo se revisó visualmente.
- Impedir aceptación de servicios desde servidor si fletero o vehículo no está aprobado o documentación obligatoria vencida. Avisos de vencimiento. No interrumpir entrega activa automáticamente.
- Al cliente mostrar solo foto de perfil, nombre de pila y datos necesarios del vehículo asignado, placas y distintivo de revisión documental; nunca imágenes de licencia, identificación o domicilio.
- Archivos en almacenamiento privado; RLS por propietario y personal autorizado, enlaces temporales, auditoría de revisión, retención y eliminación según normativa de privacidad. No incluir datos sensibles en logs.
- Cliente: verificación básica de correo y propuesta de teléfono, sin exigir documentos de identidad por defecto.
- Fase inicial propuesta: revisión manual y consultas oficiales cuando sea posible; futura integración con proveedor de identidad y prueba de vida, previa evaluación de privacidad y costo.
- Pendiente: requisitos legales de movilidad, aviso de privacidad, procedimiento de revisión, diseño y pruebas. No implementado todavía.

## Validaciones registradas — 2026-11-19
- GPS Fletero Piloto 0.5.13: prueba en carretera confirmada satisfactoria por el operador.
- Candidatos Cliente 0.3.9 y Fletero 0.5.14: artefactos firmados generados, instalación y validación financiera pendientes.
- Conciliar seis servicios históricos en efectivo completados sin confirmación registrada antes de activar los cortes.

- Operador confirma que todos los servicios históricos de Piloto fueron pruebas sin cobros reales. Conservar historial, excluir operaciones históricas de liquidaciones reales mediante identificación explícita y verificable; no marcar pagos ficticios como cobrados ni borrar pedidos. Pendiente implementación y validación de exclusión antes de activar cortes.

## Pendientes detectados durante validación financiera — 2026-11-19
- Admin: distinguir comisión por generar mientras no se confirma efectivo, pendiente de liquidación tras cobro y liquidada tras corte; comprobar redondeo y estados.
- Navegación guiada: reproducir y corregir error reportado por operador al simular navegación con direcciones seleccionadas por nombre en Cliente; comparar con coordenadas, probar origen y destino, preservar cotización y validar en Pruebas antes de Piloto.
- Efectivo Piloto: cobro, historial Cliente, estado de cuenta Fletero, reporte de falta de pago y resolución comprobados por capturas; dos servicios simulados, comisión acumulada 247.79 MXN. Cierre calculado, liquidación y datos SPEI aún pendientes de prueba controlada. Excluir nuevos servicios simulados antes del lanzamiento.


## Rediseño obligatorio de solicitud y tarifas (20 nov 2026)
- Seleccionar categoría antes de cotizar: mudanza, materiales, paquetería/entregas comerciales (incluye electrodomésticos de tienda), cada una con tarifa propia pendiente de estudio.
- Descripción obligatoria de lo transportado por categoría, cantidad, dimensiones y peso estimados; ayudantes 0–3.
- Capturar niveles de carga y descarga por separado, planta baja, escaleras, elevador y disponibilidad para carga.
- Evaluar fotos opcionales, objetos frágiles, maniobras especiales, distancia de acarreo, acceso/estacionamiento, espera, capacidad del vehículo y carga prohibida. Propuestas pendientes de aprobación.
- Mostrar desglose antes de confirmar y al fletero antes de aceptar; sincronizar Cliente, Fletero, Admin y cotización validada en servidor. Limitar a vehículos autorizados hasta 3.5 t, respetando carga útil real.
- No cambiar tarifas en Piloto hasta aprobar estudio y probar reglas en Pruebas, incluyendo regresión de efectivo, tarjeta, comisiones y reembolsos.

### GPS: pendiente prioritario de direcciones escritas
- Reproducir y corregir el fallo al introducir direcciones por texto en Cliente y luego iniciar/simular navegación en Fletero, tanto hacia recogida como entrega.
- Conservar dirección legible y coordenadas geocodificadas de cada punto; comprobar coincidencia del pin, ruta y destino de navegación. Mantener selección manual y ubicación actual.
- Validar navegación guiada, recálculo de ruta sin modificar el precio confirmado, voz y seguimiento; probar primero en Pruebas y después en Piloto.

### Tarifas iniciales acordadas provisionalmente
MXN, primeros 3 km incluidos: paquetería $400 + $45/km adicional; mudanza $500 + $50/km adicional; materiales $550 + $55/km adicional. Ajustables tras observar demanda, aceptación y rentabilidad. Extras aún por cerrar. Diseñar configuración administrable, versionada y cotización fija tras confirmar. Validar primero en Pruebas; Piloto sin cambios de precios por ahora.

### Comisión confirmada por el propietario
FLETYA cobra 15% sobre el importe total del servicio, incluidos ayudantes y suplementos. El 85% corresponde al fletero antes de sus gastos. No excluir ayudantes de la base de comisión. Extras y tratamiento fiscal aún por definir; sin cambios de código ni tarifas en Piloto.

### Ayudantes: propuesta de arranque
$300 MXN por ayudante adicional, máximo 3; comisión 15% sobre el total, incluido este concepto. Definir duración incluida y horas adicionales antes de implementación. No implica salario fijo ni cambio de tarifas en Piloto.
