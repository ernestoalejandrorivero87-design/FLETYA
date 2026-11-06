// Archived disposable-session probe; never loaded by the application.
// Temporary preview-only HTTP checks. Remove before production (PR #2).
const permissionTestAccounts = {
  clientA: '487e7dec-ea89-4969-83e4-459b9331645c',
  clientB: '271b51f1-affd-4ffd-9247-114e65917ff8',
  driverA: '6b42a407-93ef-42e3-a0a9-e2b096a0ded2',
  driverB: 'fa8c0e2e-5477-493c-9740-03f3a3c1b139'
};
function permissionCheckEnvironment() {
  return !IS_FLETYA_PRODUCTION_HOST &&
    SUPABASE_URL === 'https://ccdtpwvalqznasstnqxj.supabase.co';
}
function deniedPermissionResponse(result) {
  // A transport error or an unexpected server error is not proof of authorization.
  return result.error ? result.error.code === '42501'
    : Array.isArray(result.data) && result.data.length === 0;
}
function crossAccountPermissionTargets(account) {
  const pair = account.endsWith('A') ? 'B' : 'A';
  const driverId = permissionTestAccounts['driver' + pair];
  return [
    { table: 'jobs', label: 'service', driverId,
      id: pair === 'A' ? 'eea869cb-db09-4d5f-963b-25e5f02fe2a1' : '4ab8dfcb-f060-49b5-a5c2-0950f3ab6e2d' },
    { table: 'driver_locations', label: 'GPS', driverId,
      id: pair === 'A' ? '9bf2e657-c359-4b4e-9d61-6bec30511fe3' : '5a9977f7-5567-4b3b-8a31-bcd393380fad' }
  ];
}
async function refreshPermissionChecks() {
  if (!supabaseClient || !permissionCheckEnvironment()) return;
  const { data: { user }, error } = await supabaseClient.auth.getUser();
  document.getElementById('permissionChecks').classList.toggle('hidden',
    Boolean(error) || !Object.values(permissionTestAccounts).includes(user?.id));
}
async function checkCompletedGps(api, account, userId) {
  const jobId = account === 'driverA'
    ? 'eea869cb-db09-4d5f-963b-25e5f02fe2a1' : '4ab8dfcb-f060-49b5-a5c2-0950f3ab6e2d';
  const job = await api.from('jobs').select('id,status')
    .eq('id', jobId).eq('driver_id', userId).maybeSingle();
  if (job.error || !job.data) throw new Error('No se pudo verificar el servicio propio para probar el GPS.');
  if (job.data.status !== 'completed') return null;
  const before = await api.from('driver_locations').select('*')
    .eq('driver_id', userId).eq('job_id', jobId).maybeSingle();
  if (before.error || !before.data) throw new Error('Falta el registro histórico de GPS; prueba no ejecutada.');
  const location = before.data;
  const patch = await api.from('driver_locations').update({ driver_id: userId })
    .eq('id', location.id).eq('driver_id', userId).eq('job_id', jobId).select('id');
  // A unique driver_id already exists. A duplicate-key error is inconclusive,
  // not a pass: INSERT must be rejected specifically by row-level security.
  const insert = await api.from('driver_locations').insert({
    driver_id: userId, job_id: jobId, latitude: location.latitude,
    longitude: location.longitude, accuracy: location.accuracy
  }).select('id');
  const after = await api.from('driver_locations').select('*')
    .eq('driver_id', userId).eq('job_id', jobId).maybeSingle();
  const unchanged = !after.error && after.data &&
    ['id','driver_id','job_id','latitude','longitude','accuracy','updated_at']
      .every(key => after.data[key] === location[key]);
  return [
    { name: 'PATCH de GPS propio tras completar bloqueado', passed: deniedPermissionResponse(patch) },
    { name: 'POST de GPS propio tras completar bloqueado por RLS', passed: insert.error?.code === '42501' },
    { name: 'GPS histórico sin cambios tras las peticiones', passed: Boolean(unchanged) }
  ];
}
async function checkClientHttpPermissions(api, account, userId) {
  if (!account.startsWith('client') || permissionTestAccounts[account] !== userId) {
    throw new Error('Cuenta no válida para la prueba de cliente.');
  }
  const notificationIds = {
    clientA: '39c7c64d-6eed-4ba1-9862-5307448bd81f',
    clientB: '34c1433c-d897-4d30-97ae-18710da04f8e'
  };
  const otherAccount = account === 'clientA' ? 'clientB' : 'clientA';
  const own = await api.from('notifications').select('*')
    .eq('id', notificationIds[account]).eq('user_id', userId).maybeSingle();
  if (own.error || own.data?.message !== 'FLETYA HTTP fixture 2026-11-06') {
    throw new Error('Falta la notificación propia de prueba; casos no ejecutados.');
  }
  const otherRead = await api.from('notifications').select('id')
    .eq('id', notificationIds[otherAccount]);
  const otherWrite = await api.from('notifications').update({ read: false })
    .eq('id', notificationIds[otherAccount])
    .eq('user_id', permissionTestAccounts[otherAccount]).eq('read', false).select('id');
  const contentWrite = await api.from('notifications').update({ message: own.data.message })
    .eq('id', notificationIds[account]).eq('user_id', userId)
    .eq('message', own.data.message).select('id');
  const ownAfter = await api.from('notifications').select('*')
    .eq('id', notificationIds[account]).eq('user_id', userId).maybeSingle();
  const roleBefore = await api.from('profiles').select('role').eq('id', userId).maybeSingle();
  if (roleBefore.error || roleBefore.data?.role !== 'client') {
    throw new Error('El perfil no tiene el rol de cliente esperado; prueba detenida.');
  }
  // This disposable account's role change must fail. Stop if it unexpectedly
  // succeeds; do not execute further probes with elevated privileges.
  const roleWrite = await api.from('profiles').update({ role: 'admin' })
    .eq('id', userId).select('id,role');
  const roleAfter = await api.from('profiles').select('role').eq('id', userId).maybeSingle();
  const roleUnchanged = !roleAfter.error && roleAfter.data?.role === 'client';
  if (!roleUnchanged) throw new Error('FALLA: no se confirmó el rol de cliente tras el intento. Detener y revisar esta cuenta.');
  const roleDenied = deniedPermissionResponse(roleWrite) ||
    (roleWrite.error?.code === 'P0001' && roleWrite.error.message === 'Only an administrator can change profile roles');
  return [
    { name: 'GET/PATCH de notificación de otro cliente bloqueado',
      passed: deniedPermissionResponse(otherRead) && deniedPermissionResponse(otherWrite) },
    { name: 'PATCH del contenido de notificación propia bloqueado', passed: deniedPermissionResponse(contentWrite) },
    { name: 'Notificación propia sin cambios', passed: !ownAfter.error && Boolean(ownAfter.data) &&
      ['id','user_id','title','message','type','read','created_at','job_id'].every(key => ownAfter.data[key] === own.data[key]) },
    { name: 'PATCH directo a administrador bloqueado; rol sigue client', passed: roleDenied && roleUnchanged }
  ];
}
async function runSessionPermissionChecks() {
  const button = document.getElementById('permissionChecksButton');
  const output = document.getElementById('permissionChecksResult');
  if (button.disabled || !permissionCheckEnvironment()) return;
  button.disabled = true;
  output.textContent = 'Comprobando permisos con la sesión actual...';
  try {
    const { data: { user }, error } = await supabaseClient.auth.getUser();
    const account = Object.keys(permissionTestAccounts).find(key => permissionTestAccounts[key] === user?.id);
    if (error || !account) throw new Error('Inicia sesión con una de las cuatro cuentas temporales.');
    const lines = ['Prueba HTTP v4', 'Cuenta de prueba: ' + account];
    const probe = await supabaseClient.rpc('fletya_session_permission_probe');
    if (probe.error || !Array.isArray(probe.data?.tests)) {
      throw new Error('No se pudo ejecutar la comprobación del servidor. Código: ' + (probe.error?.code || 'respuesta inesperada'));
    }
    for (const check of probe.data.tests) {
      lines.push((check.passed === true ? 'PASA: ' : 'FALLA: ') + check.name);
    }
    lines.push('Servicio probado: ' + (probe.data.tested_job_status || 'sin servicio propio'));
    lines.push('Cambios del diagnóstico: revertidos por el servidor');
    let passed = probe.data.all_passed === true && probe.data.writes_rolled_back === true;
    const other = account.startsWith('client')
      ? permissionTestAccounts[account === 'clientA' ? 'clientB' : 'clientA']
      : permissionTestAccounts[account === 'driverA' ? 'driverB' : 'driverA'];
    // No-op PATCH, restricted to the known null value: never overwrite a name.
    const profileResult = await supabaseClient.from('profiles')
      .update({ full_name: null }).eq('id', other).is('full_name', null).select('id');
    const profilePassed = deniedPermissionResponse(profileResult);
    passed = passed && profilePassed;
    lines.push((profilePassed ? 'PASA: ' : 'FALLA: ') + 'PATCH de perfil ajeno bloqueado');
    if (account.startsWith('driver')) {
      const notification = account === 'driverA'
        ? '61675e33-6ff4-4daf-a42d-fe207b4258a6'
        : '39b843f3-4ce4-4428-b616-30eafa9329a4';
      const result = await supabaseClient.from('notifications')
        .update({ read: false }).eq('id', notification).eq('user_id', other)
        .eq('read', false).select('id');
      const notificationPassed = deniedPermissionResponse(result);
      passed = passed && notificationPassed;
      lines.push((notificationPassed ? 'PASA: ' : 'FALLA: ') + 'PATCH de notificación ajena bloqueado');
    }
    // These exact disposable rows were independently verified in the database.
    // Set driver_id to the value required by the filter: even if access control
    // regresses, the probe cannot reassign a service or change GPS coordinates.
    for (const target of crossAccountPermissionTargets(account)) {
      const before = await supabaseClient.from(target.table).select('id')
        .eq('id', target.id).eq('driver_id', target.driverId);
      const write = await supabaseClient.from(target.table)
        .update({ driver_id: target.driverId })
        .eq('id', target.id).eq('driver_id', target.driverId).select('id');
      const after = await supabaseClient.from(target.table).select('id')
        .eq('id', target.id).eq('driver_id', target.driverId);
      const blocked = deniedPermissionResponse(before) &&
        deniedPermissionResponse(write) && deniedPermissionResponse(after);
      passed = passed && blocked;
      lines.push((blocked ? 'PASA: ' : 'FALLA: ') +
        'GET/PATCH de ' + target.label + ' ajeno bloqueado');
    }
    if (account.startsWith('driver')) {
      const gpsChecks = await checkCompletedGps(supabaseClient, account, user.id);
      if (gpsChecks) {
        for (const check of gpsChecks) {
          passed = passed && check.passed;
          lines.push((check.passed ? 'PASA: ' : 'FALLA: ') + check.name);
        }
      } else {
        lines.push('PENDIENTE: GPS tras completar; este servicio sigue activo');
      }
    }
    if (account.startsWith('client')) {
      for (const check of await checkClientHttpPermissions(supabaseClient, account, user.id)) {
        passed = passed && check.passed;
        lines.push((check.passed ? 'PASA: ' : 'FALLA: ') + check.name);
      }
    }
    lines.push(passed ? 'Resultado: PASA las comprobaciones ejecutadas' : 'Resultado: REVISAR; no aprobar todavía');
    lines.push('Esta prueba no completa todos los casos HTTP pendientes del PR #2.');
    output.textContent = lines.join('\n');
  } catch (error) {
    output.textContent = 'No se completó la prueba: ' + error.message;
  } finally {
    button.disabled = false;
  }
}
if (supabaseClient && permissionCheckEnvironment()) {
  refreshPermissionChecks();
  supabaseClient.auth.onAuthStateChange(() => {
    document.getElementById('permissionChecksResult').textContent = '';
    setTimeout(refreshPermissionChecks, 0);
  });
}
