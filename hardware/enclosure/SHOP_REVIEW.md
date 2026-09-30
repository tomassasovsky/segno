# Supplier coordination — 2026-09-30

Internal notes and drafts only; nothing sent. Keep this file outside the
sheet-metal archive. The drafts are ready for the owner's approval; send nothing
until the owner says so.

State of the package (2026-09-30 integrated revision, PR #1089): the generator
and 154 enclosure tests pass, and the populated Fusion clone holds this revision.
`out/segno_sheetmetal.zip` holds exactly 12 files: STEP, DXF and PDF for base,
faceplate, ring disc and beam. The pre-cut checklist is issue #1090; the #1019
structural hold is a separate owner call and these drafts do not release it.

What changed since the 2026-09-15 drafts, as far as the shops are concerned:

- The beam has seven floor fixings (one per interior pedal gap), not fourteen.
- Every rear connector is cut into the base's rear wall; there is no rear
  panel. The two CTRL jacks sit in D-size flange plates (D punch + M3 pair).
- The floor gained Ø3.6 holes for the power boards and the earth stud moved to
  the centre of its free span. Neither changes a process step.
- **Ring disc is conditional.** If the owner chooses the 34-LED strip ring
  (#1075 bench test), its printed centre cap replaces `segno_ring_disc`: drop the
  disc and say "tres piezas" below. The faceplate is identical either way.

Matías's scope is settled: weld all four base corners and close all corner
reliefs, including the two indicated upper edges, with his 5356 filler and a
flush exterior finish that does not thin the parent sheet. Do not ask the owner
or welder to reconfirm scope or filler. Joint preparation follows the supplied
example: 0.5 mm nominal gap, 1.0 mm overlap and angular relief, Ri2 / K0.33.
The rear web is 847.821682 mm wide and the return 849.8 mm, with the transition
confined to the bend band. The lid remains removable.

Front lid fit: rear CUT slots 10 × 6 mm with OD12 washers, front Ø4.5 with OD7
washers, 1.1 mm nominal bare front gap accepted at 0.70–1.50 mm after welding
and any metal correction. The post-weld fitting/drilling provider (Matías or
Dinacut) is the owner's choice; both drafts below ask.

## Dinacut — cut, fold and deburr

Hola. Les paso la revisión final para cotizar y, si está todo bien, cortar.
Son cuatro piezas, una de cada una: base, tapa y disco en aluminio 1100-H14 de
2,0 mm, y refuerzo transversal de acero laminado en frío de 1,6 mm. Ya no hay
panel trasero: todos los conectores van cortados en la pared trasera de la
base. ¿Me confirman el grado del acero? Cada archivo indica material, espesor y
cantidad.

El trabajo de ustedes sería corte, plegado y desbarbado, sin biselado, roscado
ni pintura. Matías soldará las cuatro esquinas y cerrará sus alivios, incluidas
las dos aristas superiores indicadas. La tapa queda desmontable y no lleva
soldadura. Ya no hay escuadras ni agujeros de remache. El paquete trae STEP,
DXF y plano PDF de cada pieza (12 archivos). CUT/VENT es corte; BEND es
referencia de pliegue y DRILL no se corta por láser.

Las uniones siguen la muestra: luz nominal de 0,5 mm, solape de 1 mm y alivio
angular, con radio interior de 2 mm y K 0,33 en el aluminio (1,6 mm en el
acero). Antes de cortar necesitamos que confirmen acceso de herramienta,
secuencia de plegado y viabilidad del perfil agudo del desarrollo. Si cambian
radio, abertura de matriz o descuento de pliegue, avísenme y corrijo los
archivos antes de fabricar.

El ajuste y la perforación final de las nueve fijaciones delanteras de tapa y
cuerpo se hacen después de soldar y antes de pintar. ¿Pueden hacer esa
operación cuando la base vuelva del soldador? Si es así, cotícenla aparte. No
hace falta presentar con electrónica ni hacer una fabricación de prueba.

## Matías — agreed welding scope

Alcance aceptado: cuatro esquinas de la base de aluminio 1100-H14 de 2,0 mm,
cierre de todos sus alivios y de las dos aristas superiores indicadas, con
aporte 5356 elegido por Matías. Terminación exterior al ras para pintura lisa,
sin rebajar el espesor de la chapa. Mantener escuadra y asiento libre de la
tapa desmontable. Los taladros delanteros finales se terminan después de
soldar y antes de enviar al pintor. Este registro no constituye una nueva
consulta, un procedimiento de soldadura calificado ni autorización de corte.

### Draft to Matías: post-weld fitting (only if the owner picks him)

Hola Matías. Una consulta más sobre la base: después de soldar hay que
presentar la tapa sobre el cuerpo, controlar el asiento y la luz delantera
(entre 0,70 y 1,50 mm) y taladrar juntas las nueve fijaciones delanteras a
Ø2,5, para después agrandar las de la tapa a Ø4,5. Todo en metal, antes de
pintar, sin electrónica. ¿Lo podés hacer vos cuando termines la soldadura?
Si sí, pasame precio aparte. Te mando el plano con las cotas de las nueve
posiciones.

## Separate painter

Hola. Necesito pintura en polvo negra lisa mate RAL 9005, sin textura, en las
caras exteriores e interiores, cantos y agujeros. El conjunto incluye aluminio
y un refuerzo de acero. La previsión de diseño es de 60–100 micrones por cara;
¿pueden confirmar ese espesor también dentro de los pasos?

La base llegará con las cuatro esquinas y todos sus alivios cerrados por
soldadura, incluidas las dos aristas superiores indicadas, y todos los taladros
terminados, sin electrónica, plásticos, calces ni adhesivos. Las demás piezas
se pintan desmontadas. Los pilotos M3 llegarán sin roscar; después de pintar
yo limpiaré los pilotos y haré las roscas. No se prevé perforar nuevos agujeros
ni agrandar los pasos de tornillos después de la pintura. Son 32 roscas M3:
18 de tapa y 14 de soportes de pantalla. Solo se protegen los contactos de
masa eléctrica identificados.
