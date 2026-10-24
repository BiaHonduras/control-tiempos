// Operational apps reuse the corporate session. External links keep their own authentication.
export const INTRANET_APPS=[
 {id:'tiempos',title:'Control de Tiempos',category:'PRODUCTIVIDAD',description:'Coordina la preparación, las actividades y los tiempos de tu equipo.',path:'/control-tiempos/cronometros.html',icon:'clock'},
 {id:'contenedores',title:'Control de Reclamo a Proveedores',category:'RECEPCIÓN',description:'Registra recepciones y da seguimiento a reclamos y evidencias.',path:'/contenedores/index.html',icon:'container'},
 {id:'devoluciones',title:'Control de Devoluciones',category:'SEGUIMIENTO',description:'Ingresa devoluciones, consulta sus gestiones y prepara las entregas.',path:'/devoluciones/index.html',icon:'returns'},
 {id:'service-desk',title:'Service Desk GBS IT',category:'TICKETS',path:'https://sdp.cbc.co/app/itdesk/HomePage.do',icon:'support',external:true},
 {id:'reporteria',title:'Reportería BIA',category:'DATA',path:'http://10.240.6.232/Reports/browse',icon:'chart',external:true},
 {id:'connect',title:'Connect',category:'AUSENTISMO',path:'https://performancemanager4.successfactors.com/sf/home?bplte_company=embotelldP#/',icon:'people',external:true},
 {id:'office',title:'Inicio Office 365',category:'OFFICE',path:'https://www.office.com/',icon:'office',external:true}
];
const sitePages={SPS:'cronometros.html',CBA:'cba.html',SRC:'src.html',TGU:'tgu.html',AMT:'amt.html'};
export function applicationsFor(sedes=[],allowed=INTRANET_APPS.map(app=>app.id)){const site=['SPS','CBA','SRC','TGU','AMT'].find(s=>sedes.includes(s));return INTRANET_APPS.filter(app=>app.external||allowed.includes(app.id)).map(app=>({...app,path:app.id==='tiempos'&&site?'/control-tiempos/'+sitePages[site]:app.path}));}
export function sameOriginPath(path,origin){const url=new URL(path,origin);if(url.origin!==origin||!path.startsWith('/')||path.startsWith('//'))throw Error('La aplicación debe usar el dominio de la intranet.');return url.pathname+url.search+url.hash;}

export function applicationHref(app,origin){if(!app.external)return sameOriginPath(app.path,origin);const entry=INTRANET_APPS.find(a=>a.id===app.id&&a.external);if(!entry||entry.path!==app.path)throw Error('Enlace externo no autorizado.');return entry.path;}
