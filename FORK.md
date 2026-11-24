# IINA + biblioteca WebDAV (fork personal)

Fork de [IINA](https://github.com/iina/iina) para macOS con una pantalla de inicio propia. Licencia GPLv3, igual que el original.

## Qué añade

- **Inicio** al abrir la app: "Continuar viendo" y "Vistos recientemente" (una sola tarjeta por serie), con carátula, rating y "Te quedaste en 52:10".
- **Biblioteca** de tu servidor WebDAV, con carátulas, sinopsis y rating de TMDB, y **listas** propias (Favoritos y las que crees).
- **Series:** temporadas y capítulos con título, imagen, duración y estado de visto; el siguiente episodio se agrega solo a "Continuar viendo".
- **Reproductor:** botón **Saltar intro** (por capítulos del archivo o un salto configurable) y tarjeta de **Siguiente episodio** con reproducción automática.
- **Progreso:** se envía a tu cuenta de **Nuvio** (posición exacta, mismo formato que Nuvio web) y, opcionalmente, a **Trakt**.
- Interfaz con el estilo de IINA: barra de título transparente, material translúcido y el tema de IINA.

## Configuración (engranaje de la barra lateral)

Nada de esto viene incluido en el código; cada quien pone lo suyo:

| Sección | Qué necesita |
|---|---|
| Servidor WebDAV | URL, usuario y contraseña (se guarda en el Llavero) |
| TMDB | API key gratuita de themoviedb.org |
| Nuvio | URL del backend y clave pública de tu Nuvio, correo, contraseña y perfil |
| Trakt | Client ID de una app propia (el secret es opcional) |

## Compilar

Igual que IINA (ver `README.md`): `./other/download_libs.sh` y abrir `iina.xcodeproj` en Xcode.
El Bundle ID es `com.luis.iina-webdav`, para convivir con IINA instalado.

## Límites

- La conexión con Nuvio usa una API no documentada: puede dejar de funcionar si Nuvio la cambia.
- Pensado para uso personal; no es un proyecto oficial de IINA.
