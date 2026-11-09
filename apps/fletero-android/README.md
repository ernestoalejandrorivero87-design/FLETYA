# FLETYA Fletero · Android 0.2

Primera app nativa Android para cuentas de fletero existentes, conectada al mismo Supabase y a las políticas RLS del sitio web. La web sigue siendo el panel de administración y el cliente de referencia durante la transición. No cambia tablas, usuarios, pagos ni servicios al instalar o compilar.

## Entornos

| Variante | Identificador | Datos |
| --- | --- | --- |
| `pruebas` | `app.fletya.driver.pruebas` | Supabase de pruebas `ccdtpwvalqznasstnqxj` |
| `piloto` | `app.fletya.driver` | Supabase de producción `wsdfqscrvfygxripmrzi` |

Los dos instaladores se pueden instalar juntos. El nombre y la cabecera identifican el entorno. Las cuentas de producción no se copian a pruebas. Solo se incluyen claves públicas publicables: cada operación usa el token del usuario y RLS. Ninguna clave administrativa.

## Incluido

- Avisos push de nuevas solicitudes mediante Firebase para `piloto`; requieren autorización del servidor y activación. Ver [configuración y aceptación](../../docs/android-driver-push.md).
- Inicio con correo/contraseña, renovación de sesión y rechazo de perfiles que no sean fleteros.
- Tokens cifrados con Android Keystore, sin almacenar la contraseña; sin copias de seguridad de la sesión.
- Solicitudes disponibles (20 más recientes), aceptación condicional, recogida, liberación con motivo y finalización; confirmación por fila devuelta del servidor.
- Servicio activo, perfil con vehículo/placas, historial completado en páginas de cinco.
- Navegación externa en Google Maps al origen o al destino según la fase.
- Seguimiento nativo de ubicación iniciado con la app visible y un servicio activo; notificación persistente. Consulta de asignación antes de cada envío y validación periódica aunque no haya nuevos puntos. Se detiene por finalización, liberación, cierre de sesión o pérdida de asignación.
- Puntos obtenidos de GPS/red con edad monotónica máxima de 30 segundos; sin repetir el mismo punto como una recepción nueva; `updated_at` lo asigna la base de datos.

## Compilar

JDK 17, Gradle 8.13, Android SDK plataforma 36 y build-tools 35.0.0. AGP 8.13.2. Versiones fijadas en el proyecto y CI. Desde esta carpeta:

```sh
gradle --no-daemon testPruebasDebugUnitTest lintPruebasDebug assemblePruebasDebug assemblePilotoDebug
```

También se puede abrir esta carpeta en Android Studio. `ANDROID_HOME` debe apuntar al SDK o configurarse `sdk.dir` en `local.properties` (no se versiona). El workflow `Android fletero` compila ambos APK y conserva instaladores e informes como artefactos. Las compilaciones debug son exclusivamente de prueba; la publicación requiere firma estable de distribución y configuración de Google Play.

## Prueba de aceptación en Samsung S24+

1. Instalar la variante elegida, verificar el entorno y entrar con una cuenta de fletero existente de ese entorno.
2. Entrar con un cliente del mismo entorno en otro dispositivo. Crear una solicitud de prueba o usar una ya asignada sin modificar servicios ajenos.
3. Permitir ubicación precisa y notificaciones. La explicación aparece antes del permiso y solo se activa el seguimiento con un servicio activo. Verificar aviso de Android y nueva recepción en cliente.
4. Abrir Maps desde «Navegar al origen» y dejarlo visible cinco minutos. Observar desde el otro dispositivo que la última recepción avanza. Repetir con pantalla bloqueada y luego ahorro de batería. Anotar modelo, Android, precisión e intervalos, no inferir éxito solo al volver a abrir FLETYA.
5. Recoger: debe cambiar navegación al destino y continuar GPS. Completar: quitar notificación, dejar de enviar y mover el servicio al historial de ambos paneles.
6. En otra solicitud, liberar antes de recoger con motivo: detener GPS, devolver disponibilidad y preservar auditoría existente. No permitir liberar después de recoger.
7. Denegar/revocar permiso, apagar GPS y cortar conexión: mostrar ausencia de envío confirmado; no marcar un punto viejo como nuevo. Recuperar conexión con un punto reciente y verificar reanudación.
8. Cerrar sesión o reasignar/finalizar desde otra sesión: confirmar parada y que la cuenta anterior no envía sobre otra asignación.

## Límites y siguientes etapas

- **El GPS con Maps/pantalla apagada está implementado, pero requiere validación física.** Android y el fabricante pueden detener procesos; no se promete continuidad después de forzar detención, reiniciar, revocar permisos o quedarse sin red/batería. Esta versión no reinicia ubicación desde el arranque ni solicita `ACCESS_BACKGROUND_LOCATION`: usa un foreground service iniciado desde una actividad visible con permiso «Mientras se usa la app».
- Un proceso detenido se recupera al volver a abrir la app, consultar el servicio y activar el seguimiento. No se solicitan exenciones de batería en esta etapa.
- El rol en la interfaz es defensa adicional; los permisos decisivos siguen siendo las políticas y triggers actuales de Supabase. La preconsulta de servicio activo no sustituye una futura restricción transaccional de un solo servicio por fletero bajo aceptaciones simultáneas desde varios dispositivos.
- El cierre de sesión sin red elimina la sesión local, pero la revocación remota es de mejor esfuerzo.
- No incluye mapa embebido de referencia, registro/recuperación nativos, pagos reales, comisiones, verificación de documentos ni la app de clientes. El enlace de navegación conserva origen/destino. La web mantiene las funciones existentes durante la transición.
- Pagos, documentación y permisos legales de operación siguen pendientes antes del lanzamiento comercial.

Referencias: [servicios de ubicación Android](https://developer.android.com/develop/background-work/services/fgs/service-types#location), [restricciones de inicio](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start), [Supabase Auth REST](https://github.com/supabase/auth/blob/master/openapi.yaml).
