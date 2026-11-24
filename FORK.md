# IINA + biblioteca WebDAV (fork personal)

Fork de [IINA](https://github.com/iina/iina) para macOS con una pantalla de inicio propia. Licencia GPLv3, igual que el original.

## Qué añade

- **Portada destacada** en Inicio (fondo de la serie o película, progreso y botón Continuar) y **filas horizontales** al estilo Apple TV, con la imagen de cada episodio.
- **Carátulas también para carpetas** de release (se lee el título real del nombre) y **etiquetas de calidad** leídas del nombre del archivo (4K, DV, HDR, Remux, DTS-HD…).
- **Inicio** al abrir la app: "Continuar viendo" y "Vistos recientemente" (una sola tarjeta por serie), con carátula, rating y "Te quedaste en 52:10".
- **Biblioteca** de tu servidor WebDAV, con carátulas, sinopsis y rating de TMDB, y **listas** propias (Favoritos y las que crees).
- **Series:** temporadas y capítulos con título, imagen, duración y estado de visto; el siguiente episodio se agrega solo a "Continuar viendo".
- **Reproductor:** botón **Saltar intro** (por capítulos del archivo o un salto configurable) y tarjeta de **Siguiente episodio** con reproducción automática.
- **Progreso:** se envía a tu cuenta de **Nuvio** (posición exacta, mismo formato que Nuvio web) y, opcionalmente, a **Trakt**.
- Interfaz con el estilo de IINA: barra de título transparente, material translúcido y el tema de IINA.

## Atajos (en la ventana de la biblioteca)

| Atajo | Acción |
|---|---|
| ⌘F | Buscar |
| ⌘R | Actualizar |
| ⌘[ | Subir un nivel de carpeta |
| ⌥⌘1 / ⌥⌘2 | Ir a Inicio / Biblioteca |
| Esc | Cerrar hojas y borrar la búsqueda |

## Configuración (engranaje de la barra lateral)

Nada de esto viene incluido en el código; cada quien pone lo suyo:

| Sección | Qué necesita |
|---|---|
| Servidor WebDAV | URL, usuario y contraseña (se guarda en el Llavero) |
| TMDB | API key gratuita de themoviedb.org |
| Nuvio | URL del backend y clave pública de tu Nuvio, correo, contraseña y perfil |
| Trakt | Client ID de una app propia (el secret es opcional) |

## Instalar como app

```sh
./install-local.sh
```

Compila la versión Release para Apple Silicon y la instala como **/Applications/IINA WebDAV.app**, sin tocar tu IINA original.
El actualizador de IINA está desactivado en este fork: una actualización oficial lo reemplazaría por la IINA normal.

## Compilar

Igual que IINA (ver `README.md`): `./other/download_libs.sh` y abrir `iina.xcodeproj` en Xcode.
El Bundle ID es `com.luis.iina-webdav`, para convivir con IINA instalado.

## Límites

- La conexión con Nuvio usa una API no documentada: puede dejar de funcionar si Nuvio la cambia.
- Pensado para uso personal; no es un proyecto oficial de IINA.
