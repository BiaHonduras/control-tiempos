import { supabase, obtenerSesion, cerrarSesion } from './supabase-config.js';

let colaboradores=[];
let esAdmin=false;
const historialPrepMap=new Map();
const historialActMap=new Map();
const actividades=[
'Aseo Almacén',
'Aseo Andén | Botar Basura',
'Aseo Parqueo',
'Carga de Contenedores',
'Descarga de Contenedores',
'Despacho Rutas Detalle',
'Orden Área Asignada',
'Orden Bodega 033 | 095',
'Preparación de Facturas',
'Preparación de La Colonia',
'Preparación de Walmart',
'Recoger Tarimas Vacías | Fleje | B033 - B095',
'Preparación de Rutas de Detalle'
];
const tipos=['Café','Representada','Mixto'];
const actividadesCompartidas=new Set(['Preparación de Walmart','Preparación de La Colonia','Carga de Contenedores','Descarga de Contenedores']);
const timers=new Map();

const slug=s=>String(s).normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/\W+/g,'-').toLowerCase();
const fmt=s=>{s=Math.max(0,Number(s||0));return [Math.floor(s/3600),Math.floor((s%3600)/60),s%60].map(v=>String(v).padStart(2,'0')).join(':')};
const hoy=()=>new Date().toISOString().slice(0,10);
const esc=s=>String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]));
const keyTimer=(cat,id)=>`${cat}|${id}`;
function participantesIds(t){const ids=t?.datos?.participantes_ids;return Array.isArray(ids)&&ids.length?ids:[t?.colaborador_id].filter(Boolean)}
function timerDeColaborador(cat,id){return [...timers.values()].find(t=>t.categoria===cat&&participantesIds(t).includes(id))||null}

function segundosActuales(t){
  const base=Number(t?.segundos_acumulados||0);
  return t?.estado==='ejecucion'&&t.inicio?base+Math.max(0,Math.floor((Date.now()-new Date(t.inicio).getTime())/1000)):base;
}
function opcionesColaboradores(){return `<option value="">Seleccione un colaborador</option>${colaboradores.map(c=>`<option value="${c.id}">${esc(c.nombre)}</option>`).join('')}`}
function botones(cat){return `<button class="primary" data-requires-online data-action="start" data-cat="${cat}">Iniciar</button><button class="warn" data-requires-online data-action="pause" data-cat="${cat}">Pausar</button><button class="primary" data-requires-online data-action="resume" data-cat="${cat}">Continuar</button><button class="ok" data-requires-online data-action="finish" data-cat="${cat}">Finalizar</button><button class="danger" data-requires-online data-action="cancel" data-cat="${cat}">Cancelar</button>`}
function formularioPrep(){return `<article class="worker single-worker" id="card-prep"><h3>Preparación de pedidos</h3><div class="form"><div><label>Colaborador</label><select id="prep-colaborador">${opcionesColaboradores()}</select></div><div><label>Fecha</label><input id="prep-fecha" type="date" value="${hoy()}"></div><div><label>Zona</label><input id="prep-zona" placeholder="Zona o gira"></div><div><label>Tipo</label><select id="prep-tipo"><option value="">Seleccione</option>${tipos.map(x=>`<option>${x}</option>`).join('')}</select></div><div><label>Facturas</label><input id="prep-facturas" type="number" min="1"></div><div><label>Libras de la gira</label><input id="prep-libras" type="number" min="0" step=".01"></div></div><div class="timer" id="timer-prep">00:00:00</div><div class="desc" id="desc-prep">Seleccione un colaborador</div><div class="conflict" id="conflict-prep"></div><div class="actions">${botones('preparacion')}</div></article>`}
function formularioAct(){return `<article class="worker single-worker" id="card-act"><h3>Registro de actividad</h3><div class="form"><div id="act-single-wrap"><label>Colaborador</label><select id="act-colaborador">${opcionesColaboradores()}</select></div><div><label>Fecha</label><input id="act-fecha" type="date" value="${hoy()}"></div><div style="grid-column:span 2"><label>Actividad</label><select id="act-tipo"><option value="">Seleccione</option>${actividades.map(x=>`<option>${x}</option>`).join('')}</select></div><div id="act-shared-wrap" class="shared-selector" style="display:none;grid-column:1/-1"><label>Colaboradores participantes</label><div class="participant-grid">${colaboradores.map(c=>`<label class="participant-option"><input type="checkbox" name="act-participante" value="${c.id}"> <span>${esc(c.nombre)}</span></label>`).join('')}</div><small>Seleccione dos o más colaboradores para una actividad compartida.</small></div></div><div class="timer" id="timer-act">00:00:00</div><div class="desc" id="desc-act">Seleccione un colaborador</div><div class="conflict" id="conflict-act"></div><div class="actions">${botones('actividad')}</div></article>`}
function renderColaboradores(){
 const prepSel=document.getElementById('prep-colaborador')?.value||'';
 const actSel=document.getElementById('act-colaborador')?.value||'';
 document.getElementById('prepWorkers').innerHTML=formularioPrep();
 document.getElementById('actWorkers').innerHTML=formularioAct();
 if(colaboradores.some(c=>c.id===prepSel))document.getElementById('prep-colaborador').value=prepSel;
 if(colaboradores.some(c=>c.id===actSel))document.getElementById('act-colaborador').value=actSel;
 actualizarFormularioSeleccionado('preparacion');actualizarFormularioSeleccionado('actividad');
}
function actividadEsCompartida(){return actividadesCompartidas.has(document.getElementById('act-tipo')?.value||'')}
function idsActividadSeleccionados(){return actividadEsCompartida()?[...document.querySelectorAll('input[name="act-participante"]:checked')].map(x=>x.value):[document.getElementById('act-colaborador')?.value||''].filter(Boolean)}
function idSeleccionado(cat){return cat==='preparacion'?(document.getElementById('prep-colaborador')?.value||''):(idsActividadSeleccionados()[0]||document.getElementById('act-colaborador')?.value||'')}
function actualizarModoActividad(){const shared=actividadEsCompartida();const sw=document.getElementById('act-shared-wrap'),one=document.getElementById('act-single-wrap');if(sw)sw.style.display=shared?'block':'none';if(one)one.style.display=shared?'none':'block';actualizarFormularioSeleccionado('actividad')}
function actualizarFormularioSeleccionado(cat){
 const pref=cat==='preparacion'?'prep':'act',id=idSeleccionado(cat),card=document.getElementById(`card-${pref}`),timer=document.getElementById(`timer-${pref}`),desc=document.getElementById(`desc-${pref}`);
 card?.classList.remove('active');if(timer)timer.textContent='00:00:00';if(desc)desc.textContent=id?'Sin conteo activo para este colaborador':'Seleccione un colaborador';
 if(!id)return;const t=timerDeColaborador(cat,id);if(t)aplicarTimerFormulario(t);
}
function aplicarTimerFormulario(t){
 const pref=t.categoria==='preparacion'?'prep':'act';if(t.categoria==='preparacion'&&idSeleccionado(t.categoria)!==t.colaborador_id)return;if(t.categoria==='actividad'&&!participantesIds(t).some(id=>idsActividadSeleccionados().includes(id)))return;
 document.getElementById(`card-${pref}`)?.classList.add('active');document.getElementById(`timer-${pref}`).textContent=fmt(segundosActuales(t));
 const d=t.datos||{};document.getElementById(`desc-${pref}`).textContent=t.estado==='pausado'?'Pausado':detalleTimer(t);
 if(t.categoria==='preparacion'){document.getElementById('prep-fecha').value=d.fecha_preparacion||hoy();document.getElementById('prep-zona').value=d.zona||'';document.getElementById('prep-tipo').value=d.tipo||'';document.getElementById('prep-facturas').value=d.facturas||'';document.getElementById('prep-libras').value=d.libras||''}else{document.getElementById('act-fecha').value=d.fecha||hoy();document.getElementById('act-tipo').value=d.actividad||'';actualizarModoActividad();if(Array.isArray(d.participantes_ids)){document.querySelectorAll('input[name="act-participante"]').forEach(x=>x.checked=d.participantes_ids.includes(x.value))}else if(t.colaborador_id){document.getElementById('act-colaborador').value=t.colaborador_id}}
}
function detalleTimer(t){const d=t.datos||{};return t.categoria==='preparacion'?`${d.zona||'Sin zona'} · ${d.tipo||'Sin tipo'} · ${d.facturas||0} facturas · ${Number(d.libras||0).toFixed(2)} lb`:`${d.actividad||'Actividad sin detalle'}${Array.isArray(d.participantes_nombres)&&d.participantes_nombres.length>1?' · '+d.participantes_nombres.join(', '):''}`}
function renderActivosSuperiores(){const dock=document.getElementById('activeDock'),list=document.getElementById('activeList'),count=document.getElementById('activeCount');const activos=[...timers.values()].sort((a,b)=>String(a.empleado).localeCompare(String(b.empleado)));count.textContent=activos.length;dock.classList.toggle('visible',activos.length>0);list.innerHTML=activos.map(t=>{const paused=t.estado==='pausado';const pref=t.categoria==='preparacion'?'prep':'act';return `<article class="active-item ${paused?'paused':''}"><div class="active-item-main"><div class="active-item-top"><span class="active-kind">${t.categoria==='preparacion'?'Preparación':'Actividad'}</span><span class="active-person">${esc(t.empleado)}</span></div><div class="active-detail">${esc(detalleTimer(t))}</div></div><div><div class="active-clock" data-dock-clock="${t.id}">${fmt(segundosActuales(t))}</div><div class="active-state">${paused?'PAUSADO':'EN EJECUCIÓN'}</div></div><div class="active-quick">${esAdmin?`<button class="focus-btn" data-focus-card="${pref}|${t.colaborador_id}">Ver detalle</button>${paused?`<button class="primary" data-action="resume" data-cat="${t.categoria}" data-collab="${t.colaborador_id}">Continuar</button>`:`<button class="warn" data-action="pause" data-cat="${t.categoria}" data-collab="${t.colaborador_id}">Pausar</button>`}<button class="ok" data-action="finish" data-cat="${t.categoria}" data-collab="${t.colaborador_id}">Finalizar</button>`:`<span class="badge">Solo lectura</span>`}</div></article>`}).join('')}

document.getElementById('dockToggle')?.addEventListener('click',()=>{const d=document.getElementById('activeDock');d.classList.toggle('collapsed');document.getElementById('dockToggle').textContent=d.classList.contains('collapsed')?'Mostrar':'Ocultar'});
document.addEventListener('click',e=>{const b=e.target.closest('[data-focus-card]');if(!b)return;const [pref,id]=b.dataset.focusCard.split('|');const cat=pref==='prep'?'preparacion':'actividad';document.getElementById(`${pref}-colaborador`).value=id;actualizarFormularioSeleccionado(cat);document.getElementById(`card-${pref}`)?.scrollIntoView({behavior:'smooth',block:'center'})});
function datosFormulario(cat){if(cat==='preparacion'){const d={fecha_preparacion:document.getElementById('prep-fecha').value,zona:document.getElementById('prep-zona').value.trim(),tipo:document.getElementById('prep-tipo').value,facturas:Number(document.getElementById('prep-facturas').value||0),libras:Number(document.getElementById('prep-libras').value||0)};if(!d.fecha_preparacion||!d.zona||!d.tipo||d.facturas<=0||d.libras<0)throw new Error('Complete colaborador, fecha, zona, tipo, facturas y libras.');return d}const actividad=document.getElementById('act-tipo').value,ids=idsActividadSeleccionados(),nombres=ids.map(id=>colaboradores.find(c=>c.id===id)?.nombre).filter(Boolean);const d={fecha:document.getElementById('act-fecha').value,actividad,participantes_ids:ids,participantes_nombres:nombres};if(!d.fecha||!d.actividad)throw new Error('Seleccione fecha y actividad.');if(actividadesCompartidas.has(actividad)&&ids.length<2)throw new Error('Seleccione al menos dos colaboradores para esta actividad compartida.');if(!actividadesCompartidas.has(actividad)&&ids.length!==1)throw new Error('Seleccione un colaborador.');return d}
function mostrarConflicto(cat,msg){const el=document.getElementById(`conflict-${cat==='preparacion'?'prep':'act'}`);if(!el)return;el.textContent=msg;el.style.display='block';setTimeout(()=>el.style.display='none',6000)}
async function rpc(nombre,args){const {data,error}=await supabase.rpc(nombre,args);if(error)throw error;return data}
async function iniciar(cat){if(!esAdmin)throw new Error('SOLO_ADMINISTRADOR');const datos=datosFormulario(cat),ids=cat==='actividad'?datos.participantes_ids:[idSeleccionado(cat)];const id=ids[0];if(!id)return mostrarConflicto(cat,'Seleccione un colaborador.');if(!navigator.onLine)return mostrarConflicto(cat,'Sin conexión. La operación debe validarse en Supabase.');try{if(cat==='actividad')await rpc('iniciar_actividad_v2',{p_colaborador_ids:ids,p_datos:datos});else await rpc('iniciar_cronometro_v2',{p_categoria:cat,p_colaborador_id:id,p_datos:datos});await cargarTodo()}catch(e){mostrarConflicto(cat,e.message.includes('COLABORADOR_OCUPADO')||e.message.includes('CRONOMETRO_ACTIVO_EXISTENTE')?'Uno de los colaboradores ya tiene una actividad activa.':e.message)}}
async function accionar(cat,accion){if(!esAdmin)throw new Error('SOLO_ADMINISTRADOR');const id=idSeleccionado(cat);if(!id)return mostrarConflicto(cat,'Seleccione un colaborador.');if(!navigator.onLine)return mostrarConflicto(cat,'Sin conexión.');const t=timerDeColaborador(cat,id);if(!t)return mostrarConflicto(cat,'El colaborador seleccionado no tiene un conteo activo en este módulo.');try{if(accion==='finish')await rpc('finalizar_cronometro',{p_id:t.id,p_expected_version:t.version});else if(accion==='cancel')await rpc('cancelar_cronometro',{p_id:t.id,p_expected_version:t.version});else await rpc('cambiar_estado_cronometro',{p_id:t.id,p_expected_version:t.version,p_accion:accion});await cargarTodo()}catch(e){mostrarConflicto(cat,'Fue modificado desde otro dispositivo. Se cargará la versión vigente.');await cargarTodo()}}
document.addEventListener('click',e=>{const b=e.target.closest('button[data-action]');if(!b)return;if(!esAdmin){alert('Este usuario tiene acceso de solo lectura.');return;}const {action,cat,collab}=b.dataset;if(collab){document.getElementById(`${cat==='preparacion'?'prep':'act'}-colaborador`).value=collab;actualizarFormularioSeleccionado(cat)}action==='start'?iniciar(cat):accionar(cat,action)});
document.addEventListener('change',e=>{if(e.target.id==='prep-colaborador')actualizarFormularioSeleccionado('preparacion');if(e.target.id==='act-colaborador')actualizarFormularioSeleccionado('actividad');if(e.target.id==='act-tipo')actualizarModoActividad();if(e.target.name==='act-participante')actualizarFormularioSeleccionado('actividad')});
function aplicarTimer(t){timers.set(t.id,t);aplicarTimerFormulario(t)}
function limpiarTarjetas(){timers.clear();renderColaboradores()}
async function cargarTodo(){const [{data:cols,error:ec},{data:activos,error:e1},{data:prep,error:e2},{data:acts,error:e3}]=await Promise.all([supabase.from('colaboradores').select('*').eq('activo',true).order('orden').order('nombre'),supabase.from('cronometros').select('*').in('estado',['ejecucion','pausado']),supabase.from('historial_preparaciones').select('*').order('created_at',{ascending:false}).limit(200),supabase.from('historial_actividades').select('*').order('created_at',{ascending:false}).limit(200)]);if(ec||e1||e2||e3)throw ec||e1||e2||e3;colaboradores=cols||[];historialPrepMap.clear();(prep||[]).forEach(r=>historialPrepMap.set(r.id,r));historialActMap.clear();(acts||[]).forEach(r=>historialActMap.set(r.id,r));limpiarTarjetas();(activos||[]).forEach(aplicarTimer);renderActivosSuperiores();document.getElementById('prepHistory').innerHTML=(prep||[]).map(r=>`<tr><td>${new Date(r.created_at).toLocaleString('es-HN')}</td><td>${esc(r.empleado)}</td><td>${esc(r.zona)}</td><td>${esc(r.tipo)}</td><td>${r.facturas}</td><td>${Number(r.libras).toFixed(2)}</td><td>${fmt(r.segundos)}</td><td>${esc(r.finalizado_por_email||'')}</td>${esAdmin?`<td><div class="record-actions"><button class="edit-record-btn" data-edit-record="preparacion" data-record-id="${r.id}">Editar</button><button class="delete-record-btn" data-delete-record="preparacion" data-record-id="${r.id}">Eliminar</button></div></td>`:''}</tr>`).join('');document.getElementById('actHistory').innerHTML=(acts||[]).map(r=>`<tr><td>${new Date(r.created_at).toLocaleString('es-HN')}</td><td>${esc(r.empleado)}</td><td>${esc(r.actividad)}</td><td>${fmt(r.segundos)}</td><td>${esc(r.finalizado_por_email||'')}</td>${esAdmin?`<td><div class="record-actions"><button class="edit-record-btn" data-edit-record="actividad" data-record-id="${r.id}">Editar</button><button class="delete-record-btn" data-delete-record="actividad" data-record-id="${r.id}">Eliminar</button></div></td>`:''}</tr>`).join('');document.getElementById('conexion').textContent='Conectado. Datos sincronizados con Supabase.'}

async function verificarAdmin(userId){
 const {data,error}=await supabase.from('perfiles').select('rol').eq('id',userId).maybeSingle();
 if(error)console.error(error);
 esAdmin=data?.rol==='admin';
 document.body.classList.toggle('viewer-mode',!esAdmin);
 document.getElementById('adminOpenBtn').hidden=!esAdmin;
 document.getElementById('viewerNotice').hidden=esAdmin;
 document.getElementById('roleBadge').textContent=esAdmin?'Administrador':'Solo lectura';
 document.querySelectorAll('.admin-only-col').forEach(el=>el.hidden=!esAdmin);
 renderActivosSuperiores();
}
async function cargarAdmin(){if(!esAdmin)return;const {data,error}=await supabase.from('colaboradores').select('*').order('activo',{ascending:false}).order('orden').order('nombre');if(error)throw error;document.getElementById('collabTable').innerHTML=(data||[]).map(c=>`<tr><td>${esc(c.nombre)}</td><td>${esc(c.codigo||'')}</td><td><span class="${c.activo?'status-active':'status-inactive'}">${c.activo?'Activo':'Inactivo'}</span></td><td><button class="light" data-edit-collab='${JSON.stringify({id:c.id,nombre:c.nombre,codigo:c.codigo||''}).replace(/'/g,"&#39;")}'>Editar</button> <button class="${c.activo?'danger':'ok'}" data-toggle-collab="${c.id}" data-new-state="${!c.activo}">${c.activo?'Desactivar':'Activar'}</button></td></tr>`).join('')}
const panel=document.getElementById('adminPanel');document.getElementById('adminOpenBtn').addEventListener('click',async()=>{panel.hidden=false;await cargarAdmin();panel.scrollIntoView({behavior:'smooth'})});document.getElementById('adminCloseBtn').addEventListener('click',()=>panel.hidden=true);document.getElementById('collabCancelEdit').addEventListener('click',()=>document.getElementById('collabForm').reset());
document.getElementById('collabForm').addEventListener('submit',async e=>{e.preventDefault();const id=document.getElementById('collabId').value||null,nombre=document.getElementById('collabNombre').value.trim(),codigo=document.getElementById('collabCodigo').value.trim()||null;try{await rpc('admin_guardar_colaborador',{p_id:id,p_nombre:nombre,p_codigo:codigo});e.target.reset();document.getElementById('collabId').value='';await Promise.all([cargarAdmin(),cargarTodo()]);document.getElementById('adminMessage').textContent='Colaborador guardado correctamente.'}catch(err){document.getElementById('adminMessage').textContent=err.message}});
document.addEventListener('click',async e=>{const edit=e.target.closest('[data-edit-collab]');if(edit){const c=JSON.parse(edit.dataset.editCollab);document.getElementById('collabId').value=c.id;document.getElementById('collabNombre').value=c.nombre;document.getElementById('collabCodigo').value=c.codigo;return}const tog=e.target.closest('[data-toggle-collab]');if(tog){try{await rpc('admin_cambiar_estado_colaborador',{p_id:tog.dataset.toggleCollab,p_activo:tog.dataset.newState==='true'});await Promise.all([cargarAdmin(),cargarTodo()])}catch(err){document.getElementById('adminMessage').textContent=err.message}}});



const editModal=document.getElementById('editRecordModal');
const editForm=document.getElementById('editRecordForm');

function cerrarEditorRegistro(){
 editModal.hidden=true;
 editForm.reset();
 document.getElementById('editPrepFields').hidden=true;
 document.getElementById('editActFields').hidden=true;
}
document.getElementById('editRecordClose').addEventListener('click',cerrarEditorRegistro);
document.getElementById('editRecordCancel').addEventListener('click',cerrarEditorRegistro);
editModal.addEventListener('click',e=>{if(e.target===editModal)cerrarEditorRegistro()});

function renderParticipantesEdicion(seleccionados=[]){
 const set=new Set(seleccionados);
 document.getElementById('editParticipantes').innerHTML=colaboradores.map(c=>
  `<label><input type="checkbox" name="edit-participante" value="${c.id}" ${set.has(c.id)?'checked':''}> <span>${esc(c.nombre)}</span></label>`
 ).join('');
 actualizarAyudaParticipantesEdicion();
}
function idsParticipantesEdicion(){
 return [...document.querySelectorAll('input[name="edit-participante"]:checked')].map(x=>x.value);
}
function actualizarAyudaParticipantesEdicion(){
 const actividad=document.getElementById('editActividad').value;
 const compartida=actividadesCompartidas.has(actividad);
 document.getElementById('editParticipantHint').textContent=compartida
  ?'Esta actividad requiere dos o más colaboradores.'
  :'Esta actividad requiere exactamente un colaborador.';
}
document.getElementById('editActividad').addEventListener('change',actualizarAyudaParticipantesEdicion);

async function abrirEditorRegistro(tipo,id){
 if(!esAdmin){alert('Solo un administrador puede corregir registros.');return}
 document.getElementById('editRecordType').value=tipo;
 document.getElementById('editRecordId').value=id;
 document.getElementById('editMotivo').value='';

 if(tipo==='preparacion'){
  const r=historialPrepMap.get(id);
  if(!r)return alert('No se encontró el registro.');
  document.getElementById('editRecordTitle').textContent='Corregir preparación de pedidos';
  document.getElementById('editRecordSubtitle').textContent=`${r.empleado} · ${new Date(r.created_at).toLocaleString('es-HN')}`;
  document.getElementById('editPrepFields').hidden=false;
  document.getElementById('editActFields').hidden=true;
  document.getElementById('editFacturas').value=r.facturas;
  document.getElementById('editLibras').value=Number(r.libras).toFixed(2);
 }else{
  const r=historialActMap.get(id);
  if(!r)return alert('No se encontró el registro.');
  document.getElementById('editRecordTitle').textContent='Corregir actividad';
  document.getElementById('editRecordSubtitle').textContent=`${r.empleado} · ${new Date(r.created_at).toLocaleString('es-HN')}`;
  document.getElementById('editPrepFields').hidden=true;
  document.getElementById('editActFields').hidden=false;
  document.getElementById('editActividad').innerHTML=actividades.map(a=>`<option ${a===r.actividad?'selected':''}>${esc(a)}</option>`).join('');

  const {data:timer,error}=await supabase.from('cronometros')
    .select('colaborador_id,datos')
    .eq('id',r.timer_id)
    .maybeSingle();
  if(error){alert('No se pudieron obtener los participantes: '+error.message);return}
  const ids=Array.isArray(timer?.datos?.participantes_ids)&&timer.datos.participantes_ids.length
    ?timer.datos.participantes_ids
    :[timer?.colaborador_id||r.colaborador_id].filter(Boolean);
  renderParticipantesEdicion(ids);
 }
 editModal.hidden=false;
}

editForm.addEventListener('submit',async e=>{
 e.preventDefault();
 if(!esAdmin)return;
 const tipo=document.getElementById('editRecordType').value;
 const id=document.getElementById('editRecordId').value;
 const motivo=document.getElementById('editMotivo').value.trim();
 if(motivo.length<5){alert('Debe escribir un motivo de al menos 5 caracteres.');return}

 let cambios;
 if(tipo==='preparacion'){
  const facturas=Number(document.getElementById('editFacturas').value);
  const libras=Number(document.getElementById('editLibras').value);
  if(!Number.isInteger(facturas)||facturas<=0)return alert('Ingrese una cantidad válida de facturas.');
  if(!Number.isFinite(libras)||libras<0)return alert('Ingrese una cantidad válida de libras.');
  cambios={facturas,libras};
 }else{
  const actividad=document.getElementById('editActividad').value;
  const colaborador_ids=idsParticipantesEdicion();
  const minimo=actividadesCompartidas.has(actividad)?2:1;
  const maximo=actividadesCompartidas.has(actividad)?999:1;
  if(colaborador_ids.length<minimo||colaborador_ids.length>maximo){
   return alert(actividadesCompartidas.has(actividad)
    ?'Seleccione al menos dos colaboradores.'
    :'Seleccione exactamente un colaborador.');
  }
  cambios={actividad,colaborador_ids};
 }

 if(!confirm('¿Guardar esta corrección? La modificación quedará registrada en auditoría.'))return;
 try{
  await rpc('admin_actualizar_registro_historial',{
   p_tipo:tipo,
   p_id:id,
   p_cambios:cambios,
   p_motivo:motivo
  });
  cerrarEditorRegistro();
  await cargarTodo();
  alert('Registro corregido correctamente.');
 }catch(err){
  alert('No se pudo corregir el registro: '+err.message);
 }
});

document.addEventListener('click',e=>{
 const btn=e.target.closest('[data-edit-record]');
 if(!btn)return;
 abrirEditorRegistro(btn.dataset.editRecord,btn.dataset.recordId);
});


async function eliminarRegistroHistorial(tipo,id){
 if(!esAdmin){alert('Solo un administrador puede eliminar registros.');return}
 const etiqueta=tipo==='preparacion'?'preparación de pedidos':'actividad';
 const motivo=prompt(`Escriba el motivo para eliminar este registro de ${etiqueta}:`);
 if(motivo===null)return;
 if(motivo.trim().length<5){alert('Debe escribir un motivo de al menos 5 caracteres.');return}
 if(!confirm(`¿Confirma que desea eliminar definitivamente este registro de ${etiqueta}?\n\nLa eliminación quedará registrada en la auditoría.`))return;
 try{
  await rpc('admin_eliminar_registro_historial',{p_tipo:tipo,p_id:id,p_motivo:motivo.trim()});
  await cargarTodo();
  alert('Registro eliminado correctamente.');
 }catch(err){
  alert('No se pudo eliminar el registro: '+err.message);
 }
}
document.addEventListener('click',e=>{
 const btn=e.target.closest('[data-delete-record]');
 if(!btn)return;
 eliminarRegistroHistorial(btn.dataset.deleteRecord,btn.dataset.recordId);
});

setInterval(()=>{timers.forEach(t=>{const pref=t.categoria==='preparacion'?'prep':'act',el=document.getElementById(`timer-${pref}`);if(el&&((t.categoria==='preparacion'&&idSeleccionado(t.categoria)===t.colaborador_id)||(t.categoria==='actividad'&&participantesIds(t).some(id=>idsActividadSeleccionados().includes(id)))))el.textContent=fmt(segundosActuales(t));const d=document.querySelector(`[data-dock-clock="${t.id}"]`);if(d)d.textContent=fmt(segundosActuales(t))})},1000);
const ses=await obtenerSesion();if(!ses.ok||!ses.session)location.replace('./index.html');else{document.getElementById('userEmail').textContent=ses.session.user.email||'Usuario';await verificarAdmin(ses.session.user.id)}
window.salir=async()=>{await cerrarSesion();location.replace('./index.html')};

// ===== REPORTE EJECUTIVO EN EXCEL CON DASHBOARD Y GRÁFICOS =====
const reporteDesde=document.getElementById('reporteDesde');
const reporteHasta=document.getElementById('reporteHasta');
const descargarExcelBtn=document.getElementById('descargarExcelBtn');
const reporteMensaje=document.getElementById('reporteMensaje');

function inicializarFechasReporte(){
 const ahora=new Date();
 reporteHasta.value=ahora.toISOString().slice(0,10);
 reporteDesde.value=new Date(ahora.getFullYear(),ahora.getMonth(),1).toISOString().slice(0,10);
}
inicializarFechasReporte();
function fechaHoraReporte(valor){if(!valor)return '';return new Date(valor).toLocaleString('es-HN',{year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit'})}
function redondear(n,dec=2){const p=10**dec;return Math.round((Number(n)||0)*p)/p}
function fechaSiguiente(fecha){const d=new Date(`${fecha}T00:00:00`);d.setDate(d.getDate()+1);return d.toISOString()}
async function obtenerTodosRegistros(tabla,desde,hasta){const lote=1000;let inicio=0,todo=[];while(true){const {data,error}=await supabase.from(tabla).select('*').gte('created_at',`${desde}T00:00:00`).lt('created_at',fechaSiguiente(hasta)).order('created_at',{ascending:true}).range(inicio,inicio+lote-1);if(error)throw error;todo.push(...(data||[]));if(!data||data.length<lote)break;inicio+=lote}return todo}
function participantesActividad(registro){if(Array.isArray(registro.participantes)&&registro.participantes.length)return registro.participantes.filter(Boolean);return String(registro.empleado||'').split(',').map(x=>x.trim()).filter(Boolean)}
function descargarBlob(blob,nombre){const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=nombre;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1500)}
async function archivoABase64(url){try{const r=await fetch(url);const b=await r.blob();return await new Promise((ok,no)=>{const fr=new FileReader();fr.onload=()=>ok(String(fr.result).split(',')[1]);fr.onerror=no;fr.readAsDataURL(b)})}catch{return null}}

function dibujarBarras(datos,titulo,subtitulo,ancho=1000,alto=430){
 const c=document.createElement('canvas');c.width=ancho;c.height=alto;const x=c.getContext('2d');
 x.fillStyle='#ffffff';x.fillRect(0,0,ancho,alto);x.fillStyle='#0b2a55';x.font='bold 25px Arial';x.fillText(titulo,34,42);x.fillStyle='#667085';x.font='15px Arial';x.fillText(subtitulo,34,68);
 const top=96,left=210,right=55,bottom=42,w=ancho-left-right,h=alto-top-bottom,max=Math.max(1,...datos.map(d=>d.valor));
 x.strokeStyle='#dbe5f0';x.lineWidth=1;for(let i=0;i<=5;i++){const px=left+w*i/5;x.beginPath();x.moveTo(px,top);x.lineTo(px,top+h);x.stroke();x.fillStyle='#7a8699';x.font='12px Arial';x.fillText(redondear(max*i/5,1),px-8,top+h+22)}
 datos.forEach((d,i)=>{const rh=Math.min(38,h/Math.max(1,datos.length)-9),y=top+i*(h/datos.length)+(h/datos.length-rh)/2,bw=w*d.valor/max;x.fillStyle='#e9f1ff';x.fillRect(left,y,w,rh);x.fillStyle=i===0?'#1264d8':'#3d85e8';x.fillRect(left,y,bw,rh);x.fillStyle='#172b4d';x.font='bold 14px Arial';x.textAlign='right';x.fillText(d.nombre,left-12,y+rh/2+5);x.textAlign='left';x.fillStyle='#0b2a55';x.fillText(redondear(d.valor,2),left+bw+9,y+rh/2+5)});
 return c.toDataURL('image/png').split(',')[1];
}
function dibujarDona(datos,titulo,ancho=900,alto=430){
 const c=document.createElement('canvas');c.width=ancho;c.height=alto;const x=c.getContext('2d');x.fillStyle='#fff';x.fillRect(0,0,ancho,alto);x.fillStyle='#0b2a55';x.font='bold 25px Arial';x.fillText(titulo,34,42);
 const colores=['#1264d8','#20a66a','#f59e0b','#7c5ce7','#ec5b5b','#16a3b6','#6b7a90','#9bc53d'];const total=Math.max(1,datos.reduce((s,d)=>s+d.valor,0));let ini=-Math.PI/2,cx=245,cy=235,r=135;
 datos.forEach((d,i)=>{const ang=2*Math.PI*d.valor/total;x.beginPath();x.moveTo(cx,cy);x.arc(cx,cy,r,ini,ini+ang);x.closePath();x.fillStyle=colores[i%colores.length];x.fill();ini+=ang});x.beginPath();x.arc(cx,cy,72,0,Math.PI*2);x.fillStyle='#fff';x.fill();x.textAlign='center';x.fillStyle='#0b2a55';x.font='bold 28px Arial';x.fillText(redondear(total,1),cx,cy+4);x.font='13px Arial';x.fillStyle='#667085';x.fillText('horas-hombre',cx,cy+28);x.textAlign='left';
 datos.slice(0,8).forEach((d,i)=>{const y=95+i*37;x.fillStyle=colores[i%colores.length];x.fillRect(455,y-12,16,16);x.fillStyle='#172b4d';x.font='14px Arial';const nombre=d.nombre.length>36?d.nombre.slice(0,34)+'…':d.nombre;x.fillText(nombre,480,y);x.fillStyle='#667085';x.fillText(`${redondear(d.valor,1)} h · ${redondear(d.valor/total*100,1)}%`,720,y)});return c.toDataURL('image/png').split(',')[1]
}
function dibujarTendencia(datos,titulo,ancho=1000,alto=430){
 const c=document.createElement('canvas');c.width=ancho;c.height=alto;const x=c.getContext('2d');x.fillStyle='#fff';x.fillRect(0,0,ancho,alto);x.fillStyle='#0b2a55';x.font='bold 25px Arial';x.fillText(titulo,34,42);x.fillStyle='#667085';x.font='14px Arial';x.fillText('Facturas preparadas por día',34,67);
 const top=96,left=75,right=35,bottom=62,w=ancho-left-right,h=alto-top-bottom,max=Math.max(1,...datos.map(d=>d.valor));x.strokeStyle='#dbe5f0';for(let i=0;i<=5;i++){const y=top+h-h*i/5;x.beginPath();x.moveTo(left,y);x.lineTo(left+w,y);x.stroke();x.fillStyle='#7a8699';x.font='12px Arial';x.fillText(Math.round(max*i/5),25,y+4)}
 if(datos.length){x.strokeStyle='#1264d8';x.lineWidth=4;x.beginPath();datos.forEach((d,i)=>{const px=left+(datos.length===1?w/2:w*i/(datos.length-1)),py=top+h-h*d.valor/max;i?x.lineTo(px,py):x.moveTo(px,py)});x.stroke();datos.forEach((d,i)=>{const px=left+(datos.length===1?w/2:w*i/(datos.length-1)),py=top+h-h*d.valor/max;x.fillStyle='#1264d8';x.beginPath();x.arc(px,py,5,0,Math.PI*2);x.fill();if(i%Math.ceil(datos.length/9)===0||i===datos.length-1){x.save();x.translate(px,top+h+20);x.rotate(-.45);x.fillStyle='#667085';x.font='12px Arial';x.fillText(d.nombre,0,0);x.restore()}})}return c.toDataURL('image/png').split(',')[1]
}

function estilosHojaDetalle(ws,anchos){ws.views=[{state:'frozen',ySplit:1}];ws.autoFilter={from:'A1',to:{row:1,column:anchos.length}};ws.columns=anchos.map((w,i)=>({key:`c${i}`,width:w}));const h=ws.getRow(1);h.height=28;h.eachCell(c=>{c.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FF0B2A55'}};c.font={bold:true,color:{argb:'FFFFFFFF'}};c.alignment={vertical:'middle',horizontal:'center',wrapText:true}});ws.eachRow((row,n)=>{if(n>1){row.height=22;row.eachCell(c=>{c.alignment={vertical:'middle',wrapText:true};c.border={bottom:{style:'hair',color:{argb:'FFD9E2EC'}}}})}})}
function agregarKpi(ws,r1,c1,r2,c2,titulo,valor,formato){ws.mergeCells(r1,c1,r2,c2);const celda=ws.getCell(r1,c1);celda.value={richText:[{text:`${titulo}\n`,font:{size:11,bold:true,color:{argb:'FF52647A'}}},{text:String(valor),font:{size:23,bold:true,color:{argb:'FF0B2A55'}}}]};celda.alignment={vertical:'middle',horizontal:'center',wrapText:true};celda.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FFF4F8FD'}};celda.border={top:{style:'thin',color:{argb:'FFC8D8EA'}},bottom:{style:'thin',color:{argb:'FFC8D8EA'}},left:{style:'thin',color:{argb:'FFC8D8EA'}},right:{style:'thin',color:{argb:'FFC8D8EA'}}};if(formato)celda.numFmt=formato}

async function construirReporte(preparaciones,actividades,desde,hasta){
 const wb=new ExcelJS.Workbook();wb.creator='BIA Honduras';wb.created=new Date();wb.title='Reporte Ejecutivo de Productividad';
 const personas=new Map(),porActividad=new Map(),porDia=new Map();const asegurar=n=>{if(!personas.has(n))personas.set(n,{nombre:n,preparaciones:0,facturas:0,libras:0,segundosPrep:0,actividades:0,segundosActividad:0});return personas.get(n)};
 preparaciones.forEach(r=>{const p=asegurar(r.empleado||'Sin colaborador');p.preparaciones++;p.facturas+=Number(r.facturas||0);p.libras+=Number(r.libras||0);p.segundosPrep+=Number(r.segundos||0);const dia=String(r.fecha_preparacion||r.created_at).slice(0,10);porDia.set(dia,(porDia.get(dia)||0)+Number(r.facturas||0))});
 actividades.forEach(r=>{const lista=participantesActividad(r);const ps=lista.length?lista:['Sin colaborador'];ps.forEach(n=>{const p=asegurar(n);p.actividades++;p.segundosActividad+=Number(r.segundos||0)});const k=r.actividad||'Sin actividad';if(!porActividad.has(k))porActividad.set(k,{nombre:k,registros:0,segundos:0,horasHombre:0});const a=porActividad.get(k);a.registros++;a.segundos+=Number(r.segundos||0);a.horasHombre+=(Number(r.segundos||0)/3600)*ps.length});
 const tf=preparaciones.reduce((s,r)=>s+Number(r.facturas||0),0),tl=preparaciones.reduce((s,r)=>s+Number(r.libras||0),0),sp=preparaciones.reduce((s,r)=>s+Number(r.segundos||0),0),sa=actividades.reduce((s,r)=>s+Number(r.segundos||0),0),hh=actividades.reduce((s,r)=>s+(Number(r.segundos||0)/3600)*Math.max(1,participantesActividad(r).length),0),hp=sp/3600;
 const listaPersonas=[...personas.values()].sort((a,b)=>b.facturas-a.facturas),listaAct=[...porActividad.values()].sort((a,b)=>b.horasHombre-a.horasHombre),listaDias=[...porDia.entries()].sort().map(([nombre,valor])=>({nombre,valor}));
 const dash=wb.addWorksheet('Dashboard Ejecutivo',{views:[{showGridLines:false}]});dash.columns=Array.from({length:14},()=>({width:12}));dash.getRow(1).height=38;dash.mergeCells('A1:N2');dash.getCell('A1').value='BIA HONDURAS · DASHBOARD DE PRODUCTIVIDAD';dash.getCell('A1').fill={type:'pattern',pattern:'solid',fgColor:{argb:'FF061D3B'}};dash.getCell('A1').font={bold:true,size:22,color:{argb:'FFFFFFFF'}};dash.getCell('A1').alignment={vertical:'middle',horizontal:'center'};dash.mergeCells('A3:N3');dash.getCell('A3').value=`Período analizado: ${desde} al ${hasta} · Generado: ${fechaHoraReporte(new Date())}`;dash.getCell('A3').font={italic:true,color:{argb:'FF52647A'}};dash.getCell('A3').alignment={horizontal:'center'};
 agregarKpi(dash,5,1,7,2,'PREPARACIONES',preparaciones.length);agregarKpi(dash,5,3,7,4,'FACTURAS',tf);agregarKpi(dash,5,5,7,6,'LIBRAS',redondear(tl));agregarKpi(dash,5,7,7,8,'FACTURAS / HORA',redondear(hp?tf/hp:0));agregarKpi(dash,5,9,7,10,'LIBRAS / HORA',redondear(hp?tl/hp:0));agregarKpi(dash,5,11,7,12,'ACTIVIDADES',actividades.length);agregarKpi(dash,5,13,7,14,'HORAS PRODUCTIVAS',redondear(hp+hh));
 const logo=await archivoABase64('./assets/bia-honduras-logo.png');if(logo){const id=wb.addImage({base64:logo,extension:'png'});dash.addImage(id,{tl:{col:.15,row:.15},ext:{width:125,height:55}})}
 const chart1=wb.addImage({base64:dibujarBarras(listaPersonas.slice(0,7).map(p=>({nombre:p.nombre,valor:p.segundosPrep? p.facturas/(p.segundosPrep/3600):0})),'Productividad por colaborador','Facturas por hora'),extension:'png'});dash.addImage(chart1,{tl:{col:.2,row:8},ext:{width:650,height:280}});
 const chart2=wb.addImage({base64:dibujarDona(listaAct.slice(0,8).map(a=>({nombre:a.nombre,valor:a.horasHombre})),'Distribución de horas-hombre'),extension:'png'});dash.addImage(chart2,{tl:{col:7.2,row:8},ext:{width:590,height:280}});
 const chart3=wb.addImage({base64:dibujarTendencia(listaDias,'Tendencia diaria de preparación'),extension:'png'});dash.addImage(chart3,{tl:{col:.2,row:24},ext:{width:650,height:280}});
 const chart4=wb.addImage({base64:dibujarBarras(listaPersonas.slice(0,7).map(p=>({nombre:p.nombre,valor:(p.segundosPrep+p.segundosActividad)/3600})),'Horas productivas por colaborador','Preparación + horas-hombre de actividades'),extension:'png'});dash.addImage(chart4,{tl:{col:7.2,row:24},ext:{width:590,height:280}});dash.getRow(40).height=25;dash.mergeCells('A40:N40');dash.getCell('A40').value='Nota: en actividades compartidas, cada participante recibe el tiempo completo como horas-hombre.';dash.getCell('A40').fill={type:'pattern',pattern:'solid',fgColor:{argb:'FFFFF5DB'}};dash.getCell('A40').font={italic:true,color:{argb:'FF7A4D00'}};dash.getCell('A40').alignment={horizontal:'center'};
 const prod=wb.addWorksheet('Productividad Colaborador');prod.addRow(['Colaborador','Preparaciones','Facturas','Libras','Horas preparación','Facturas/hora','Libras/hora','Minutos/factura','Actividades','Horas-hombre actividades','Total horas productivas']);listaPersonas.sort((a,b)=>a.nombre.localeCompare(b.nombre,'es')).forEach(p=>{const h=p.segundosPrep/3600,ha=p.segundosActividad/3600;prod.addRow([p.nombre,p.preparaciones,p.facturas,redondear(p.libras),redondear(h),redondear(h?p.facturas/h:0),redondear(h?p.libras/h:0),redondear(p.facturas?(p.segundosPrep/60)/p.facturas:0),p.actividades,redondear(ha),redondear(h+ha)])});estilosHojaDetalle(prod,[28,15,12,14,18,16,16,18,14,23,22]);prod.getColumn(4).numFmt='#,##0.00';for(let c=5;c<=11;c++)prod.getColumn(c).numFmt='#,##0.00';
 const prep=wb.addWorksheet('Preparaciones');prep.addRow(['Fecha y hora','Fecha preparación','Colaborador','Zona / Gira','Tipo','Facturas','Libras','Tiempo','Minutos','Facturas/hora','Libras/hora','Minutos/factura','Finalizado por']);preparaciones.forEach(r=>{const h=Number(r.segundos||0)/3600;prep.addRow([fechaHoraReporte(r.created_at),r.fecha_preparacion||'',r.empleado||'',r.zona||'',r.tipo||'',Number(r.facturas||0),redondear(r.libras),fmt(Number(r.segundos||0)),redondear(Number(r.segundos||0)/60),redondear(h?Number(r.facturas||0)/h:0),redondear(h?Number(r.libras||0)/h:0),redondear(Number(r.facturas||0)?(Number(r.segundos||0)/60)/Number(r.facturas):0),r.finalizado_por_email||''])});estilosHojaDetalle(prep,[21,18,25,20,16,11,14,16,12,15,15,18,27]);prep.getColumn(7).numFmt='#,##0.00';for(let c=9;c<=12;c++)prep.getColumn(c).numFmt='#,##0.00';
 const act=wb.addWorksheet('Actividades');act.addRow(['Fecha y hora','Fecha actividad','Actividad','Colaboradores','# Participantes','Tiempo','Minutos','Horas cronológicas','Horas-hombre','Finalizado por']);actividades.forEach(r=>{const ps=participantesActividad(r),cant=Math.max(1,ps.length),h=Number(r.segundos||0)/3600;act.addRow([fechaHoraReporte(r.created_at),r.fecha||'',r.actividad||'',(ps.length?ps:[r.empleado||'']).join(', '),cant,fmt(Number(r.segundos||0)),redondear(Number(r.segundos||0)/60),redondear(h),redondear(h*cant),r.finalizado_por_email||''])});estilosHojaDetalle(act,[21,17,38,44,15,16,12,19,16,27]);for(let c=7;c<=9;c++)act.getColumn(c).numFmt='#,##0.00';
 const ra=wb.addWorksheet('Resumen Actividades');ra.addRow(['Actividad','# Registros','Horas cronológicas','Horas-hombre','Promedio minutos']);listaAct.forEach(a=>ra.addRow([a.nombre,a.registros,redondear(a.segundos/3600),redondear(a.horasHombre),redondear(a.registros?(a.segundos/60)/a.registros:0)]));estilosHojaDetalle(ra,[42,14,20,16,18]);for(let c=3;c<=5;c++)ra.getColumn(c).numFmt='#,##0.00';
 return wb;
}

descargarExcelBtn.addEventListener('click',async()=>{const desde=reporteDesde.value,hasta=reporteHasta.value;if(!desde||!hasta)return alert('Seleccione la fecha inicial y final.');if(desde>hasta)return alert('La fecha inicial no puede ser mayor que la fecha final.');if(!navigator.onLine)return alert('Se necesita conexión para consultar la información de Supabase.');if(typeof ExcelJS==='undefined')return alert('No se pudo cargar el generador de Excel. Revise la conexión.');const original=descargarExcelBtn.textContent;descargarExcelBtn.disabled=true;descargarExcelBtn.textContent='Generando dashboard...';reporteMensaje.textContent='Consultando información y construyendo gráficos ejecutivos...';try{const [p,a]=await Promise.all([obtenerTodosRegistros('historial_preparaciones',desde,hasta),obtenerTodosRegistros('historial_actividades',desde,hasta)]);if(!p.length&&!a.length){reporteMensaje.textContent='No se encontraron registros en el período seleccionado.';return}const libro=await construirReporte(p,a,desde,hasta),buffer=await libro.xlsx.writeBuffer();descargarBlob(new Blob([buffer],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'}),`Dashboard_Productividad_BIA_${desde}_al_${hasta}.xlsx`);reporteMensaje.textContent=`Dashboard generado con ${p.length} preparaciones y ${a.length} actividades.`}catch(err){console.error(err);reporteMensaje.textContent='No se pudo generar el reporte: '+err.message}finally{descargarExcelBtn.disabled=false;descargarExcelBtn.textContent=original}});

supabase.channel('cronometros-operacion-v21').on('postgres_changes',{event:'*',schema:'public',table:'cronometros'},()=>cargarTodo()).on('postgres_changes',{event:'*',schema:'public',table:'historial_preparaciones'},()=>cargarTodo()).on('postgres_changes',{event:'*',schema:'public',table:'historial_actividades'},()=>cargarTodo()).on('postgres_changes',{event:'*',schema:'public',table:'colaboradores'},()=>{cargarTodo();if(esAdmin)cargarAdmin()}).subscribe();
try{await cargarTodo()}catch(e){document.getElementById('conexion').textContent='No se pudo cargar la información: '+e.message}
