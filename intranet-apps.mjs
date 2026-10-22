// Add a future application here. Routes must remain on the corporate origin
// so they can reuse the existing Supabase session without a token in the URL.
export const INTRANET_APPS=[
 {id:'tiempos',title:'Control de Tiempos',category:'PRODUCTIVIDAD',description:'Coordina la preparación, las actividades y los tiempos de tu equipo.',path:'/control-tiempos/cronometros.html',icon:'clock'},
 {id:'contenedores',title:'Control de Contenedores',category:'RECEPCIÓN',description:'Registra recepciones y da seguimiento a reclamos y evidencias.',path:'/contenedores/index.html',icon:'container'},
 {id:'devoluciones',title:'Control de Devoluciones',category:'SEGUIMIENTO',description:'Ingresa devoluciones, consulta sus gestiones y prepara las entregas.',path:'/devoluciones/index.html',icon:'returns'}
];
const sitePages={SPS:'cronometros.html',CBA:'cba.html',SRC:'src.html',TGU:'tgu.html',AMT:'amt.html'};
export function applicationsFor(sedes=[]){const site=['SPS','CBA','SRC','TGU','AMT'].find(s=>sedes.includes(s));return INTRANET_APPS.map(app=>({...app,path:app.id==='tiempos'&&site?'/control-tiempos/'+sitePages[site]:app.path}));}
export function sameOriginPath(path,origin){const url=new URL(path,origin);if(url.origin!==origin||!path.startsWith('/')||path.startsWith('//'))throw Error('La aplicación debe usar el dominio de la intranet.');return url.pathname+url.search+url.hash;}
