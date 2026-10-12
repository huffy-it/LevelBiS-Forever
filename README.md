# LevelBiS

Addon para **World of Warcraft TBC Anniversary (cliente 2.5.x)** que te dice qué
equipo conseguir mientras subes del nivel 1 al 70.

- Mira lo que llevas puesto y, ranura por ranura, te propone algo mejor que
  puedas equipar y conseguir.
- Te dice **por dónde empezar**: la ranura donde más ganas.
- Funciona sin internet y sin listas BiS hechas a mano: puntúa cada objeto con
  los pesos de estadísticas de tu especialización.

Versión actual: `0.18.0-look`.

---

## Instalación

1. Copia la carpeta `LevelBiS/` en `World of Warcraft/_classic_/Interface/AddOns/`.
2. Entra al juego y escribe `/lbis` (o pulsa el botón del minimapa).

Si el addon aparece como «desactualizado», activa «Cargar accesorios
desactualizados» en la pantalla de selección de personaje.

---

## Primeros pasos

Abre la ventana con `/lbis`. Verás tus 17 ranuras de equipo en tres grupos
(armadura, accesorios y armas):

| Columna | Qué significa |
|---|---|
| **Llevas** | Lo que tienes puesto y su puntaje. |
| **Mejora disponible** | Barra gris: lo que ya tienes. Tramo turquesa: lo que ganarías. |
| **Recomendado** | El mejor objeto que puedes conseguir, en el color de su calidad. A la derecha, de dónde sale (`Maz`, `Raid`, `Mis`, `Ven`, `Fab`, `PvP`, `Mun`) y cómo se liga (`BoP`, `BoE`, `BoU`). |
| **Ganas** | Cuánto mejora esa ranura, en porcentaje. «al día» significa que ya llevas lo mejor. |

La frase de arriba y la fila con borde turquesa («**Empieza aquí**») marcan la
ranura que más puntos suma. Ojo: el porcentaje más alto no siempre es la mayor
mejora, porque cada ranura parte de un puntaje distinto.

### Clics sobre un objeto recomendado

- **Pasar el cursor:** muestra su tooltip.
- **Clic:** abre el detalle de la fila (otro clic lo cierra).
- **Shift-clic:** enlaza el objeto en el chat.
- **Ctrl-clic:** lo prueba en el probador.
- **Con la subasta abierta:** el clic lo busca en la subasta y Alt-clic abre el detalle.

### El detalle

Al hacer clic en una fila verás:

- qué objeto sustituye y qué estadísticas ganas (turquesa) o pierdes (rojo);
- de dónde sale y desde qué nivel puedes ir a buscarlo;
- por qué puntúa así y hasta qué nivel te seguirá sirviendo;
- el precio que viste en la subasta, si lo hay;
- la **mejor alternativa sin tirada aleatoria** y cuánto pierdes eligiéndola, por
  si no quieres perseguir un sufijo concreto («del Oso», «del Tigre»…).

---

## Pestañas

- **Equipo:** la lista de ranuras descrita arriba.
- **Mazmorras:** «¿Qué mazmorra corro?». Te sugiere las mazmorras que más
  mejoras te dan para tu nivel y tus filtros.
- **Consumibles:** frasco o elixires, comida y pociones que más te convienen,
  calculados con tus pesos.

---

## Filtros

Pulsa **Mostrar filtros** para verlos. Debajo siempre aparece un resumen de lo
que está activo, y **Restablecer filtros** vuelve a los valores iniciales.

**Casillas**

| Casilla | Al inicio | Qué hace |
|---|---|---|
| Sin raid | Activada | Oculta lo que solo cae en raid. |
| Instancias | Desactivada | Solo drops y vendedores de mazmorras o raids. |
| Misiones | Desactivada | Solo recompensas de misión. Se puede combinar con Instancias. |
| Mis profesiones | Activada | Oculta lo que pide una profesión que no tienes. |
| Alcanzable | Activada | Solo lo que de verdad puedes conseguir: nivel suficiente, reputación suficiente, misiones que aún no hiciste y nada de eventos de temporada (Fiesta de la Cerveza, Halloween…). |

**Botones** (cada clic pasa a la siguiente opción)

| Botón | Opciones |
|---|---|
| Tiradas | **mejor**: cuenta la mejor tirada posible de los objetos aleatorios · **ignorar**: solo cuenta lo garantizado · **excluir**: oculta los objetos aleatorios. |
| Subasta | **incluir** · **excluir**: oculta lo que se compra en la subasta · **solo**: solo lo que se puede comprar. |
| Orden | **ranura** · **mejora**: de mayor a menor ganancia, con una línea donde se junta el 70% de tu mejora · **oro**: lo que más rinde por moneda, según los precios que viste. |

**Fila del nivel**

- `<` `>` y **Actual**: elige para qué nivel quieres la recomendación.
- **Objetivo: leveling / nivel 70**: el modo nivel 70 incluye raids, heroicas y
  la fase abierta. Al volver a «leveling» recuperas tus filtros.
- **Mazmorras: todas / normales / heroicas**.
- **Fase**: hasta qué fase del servidor se cuenta el contenido. Por defecto, la
  fase actual.

---

## Panel «Pesos»

El botón **Pesos** (arriba a la derecha) abre el editor de pesos de tu
especialización. Ahí puedes cambiar cuánto vale cada estadística, importar o
exportar escalas de Pawn y volver al preajuste.

También tiene cuatro ajustes:

- **Pesos por nivel** (activado): los índices como golpe o crítico valen más a
  niveles bajos; esta casilla lo tiene en cuenta.
- **Tope de ilvl**: oculta objetos con un nivel muy por encima de lo habitual.
- **Tope de golpe (70)**: a nivel 70 no valora el golpe que pasa del tope.
- **Avisos de bolsas**: te avisa en el chat si algo de tus bolsas mejora una
  ranura (solo con la ventana abierta).

---

## Mientras juegas

- **Misiones:** al aceptar o entregar una misión con varias recompensas, el chat
  te dice cuál elegir. Si ninguna te mejora, te sugiere la que más se vende.
- **Botín de grupo:** al tirar por un objeto te dice si te conviene Necesidad o
  Codicia.
- **Subir de nivel:** el chat te avisa de las mejoras que se abren.
- **Tooltips:** cualquier objeto muestra cuánto mejoraría tu equipo.
- **Subasta:** el addon recuerda los precios que ves al buscar (de cada tirada
  por separado) durante 30 días. No hace búsquedas por su cuenta.

---

## Comandos

| Comando | Qué hace |
|---|---|
| `/lbis` | Abre o cierra la ventana. |
| `/lbis help` | Ayuda y nombres de las ranuras. |
| `/lbis summary` | Resumen de las 17 ranuras en el chat. |
| `/lbis slot <ranura>` | Las mejores opciones de una ranura. |
| `/lbis spec [nombre\|auto]` | Ver o fijar tu especialización. |
| `/lbis level [n\|next]` | Cambiar el nivel objetivo. |
| `/lbis edit` | Abrir el editor de pesos. |
| `/lbis filter [nombre] [on\|off]` | Ver o cambiar filtros, incluidos los que no tienen casilla (Mi armadura, Mi facción, Sin PvP). |
| `/lbis sort [ranura\|mejora\|oro]` | Cambiar el orden. |
| `/lbis consumibles` | Consumibles recomendados en el chat. |
| `/lbis quest` | Qué recompensa elegir en la misión seleccionada. |
| `/lbis bags [on\|off]`, `/lbis equip` | Avisos de bolsas y equipar la última mejora avisada. |
| `/lbis rolls [on\|off]` | Consejos al tirar por botín. |
| `/lbis profs sim` | Qué profesión te daría más equipo. |
| `/lbis phase [1-5\|auto]` | Fase del servidor. |
| `/lbis goal [70\|leveling]` | Cambiar entre leveling y nivel 70. |
| `/lbis access` | Qué lee el addon de tu reputación y tus misiones. |
| `/lbis import <escala>`, `/lbis export` | Importar o exportar una escala de Pawn. |
| `/lbis explain <itemID>` | Desglose del puntaje de un objeto. |
| `/lbis errors` | Errores registrados por el addon. |

Ranuras: `head neck shoulder chest waist legs feet wrist hands finger1 finger2
trinket1 trinket2 back mainhand offhand ranged`.

---

## Qué debes saber

- **El puntaje no es DPS.** Es la suma de estadísticas según los pesos de tu
  especialización. Sirve para comparar objetos, no para simular combate.
- **Gemas y encantamientos no cuentan**, ni en lo que llevas ni en lo recomendado.
- **Los efectos especiales** (procs y efectos al usar) se describen, pero no se
  puntúan: no hay forma fiable de darles un número.
- **Las probabilidades de botín** vienen de cmangos y son aproximadas.
- **Los eventos de temporada** no se detectan: durante una festividad, apaga
  «Alcanzable» para ver sus objetos.
- **Alcanzable** comprueba nivel, reputación y misiones, pero no llaves, cadenas
  de misiones ni sintonías.

---

## Datos

La base incluye 11.544 objetos generados a partir de los datos abiertos de
cmangos (TBC 2.4.3) y de las tablas del cliente. No se inventan
identificadores, estadísticas ni probabilidades: si un dato no está en la
fuente, se omite.
