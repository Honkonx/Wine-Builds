#!/usr/bin/env bash

########################################################################
##
## A script for Wine compilation.
## Modified for custom Proton repository (KreitinnSoftware)
## Fixed: Uses generic GCC instead of hardcoded gcc-11
## Updated: Bootstraps set to Ubuntu 24.04 (Noble)
##
########################################################################

# Prevent launching as root
if [ $EUID = 0 ] && [ -z "$ALLOW_ROOT" ]; then
	echo "Do not run this script as root!"
	echo
	echo "If you really need to run it as root and you know what you are doing,"
	echo "set the ALLOW_ROOT environment variable."

	exit 1
fi

# Wine version to compile.
export WINE_VERSION="${WINE_VERSION:-latest}"

# Available branches: vanilla, staging, proton, staging-tkg, staging-tkg-ntsync
export WINE_BRANCH="${WINE_BRANCH:-staging}"

# Proton configuration
export PROTON_BRANCH="${PROTON_BRANCH:-proton_9.0}"

# Staging configuration
export STAGING_VERSION="${STAGING_VERSION:-}"
export STAGING_ARGS="${STAGING_ARGS:-}"

# Experimental options
export EXPERIMENTAL_WOW64="${EXPERIMENTAL_WOW64:-false}"

# Custom source path
export CUSTOM_SRC_PATH=""

# Script control
export DO_NOT_COMPILE="false"
export USE_CCACHE="false"

export WINE_BUILD_OPTIONS="--without-ldap --without-oss --disable-winemenubuilder --disable-win16 --disable-tests"

# Directories
export BUILD_DIR="${HOME}"/build_wine

# ----------------------------------------------------------------------
# ACTUALIZACIÓN DE BOOTSTRAPS
# ----------------------------------------------------------------------
# Configurado para Ubuntu 24.04 (Noble Numbat)
# Si quisieras usar 22.04, cambia 'noble' por 'jammy'
export BOOTSTRAP_X64=/opt/chroots/noble64_chroot
export BOOTSTRAP_X32=/opt/chroots/noble32_chroot
# ----------------------------------------------------------------------

export scriptdir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# ----------------------------------------------------------------------
# CORRECCIÓN DE COMPILADOR
# ----------------------------------------------------------------------
# Antes forzaba gcc-11. Ahora usa el defecto del sistema.
export CC="gcc"
export CXX="g++"

export CROSSCC_X32="i686-w64-mingw32-gcc"
export CROSSCXX_X32="i686-w64-mingw32-g++"
export CROSSCC_X64="x86_64-w64-mingw32-gcc"
export CROSSCXX_X64="x86_64-w64-mingw32-g++"
# ----------------------------------------------------------------------

export CFLAGS_X32="-march=i686 -msse2 -mfpmath=sse -O2 -ftree-vectorize"
export CFLAGS_X64="-march=x86-64 -msse3 -mfpmath=sse -O2 -ftree-vectorize"
export LDFLAGS="-Wl,-O1,--sort-common,--as-needed"

export CROSSCFLAGS_X32="${CFLAGS_X32}"
export CROSSCFLAGS_X64="${CFLAGS_X64}"
export CROSSLDFLAGS="${LDFLAGS}"

if [ "$USE_CCACHE" = "true" ]; then
	export CC="ccache ${CC}"
	export CXX="ccache ${CXX}"

	export i386_CC="ccache ${CROSSCC_X32}"
	export x86_64_CC="ccache ${CROSSCC_X64}"

	export CROSSCC_X32="ccache ${CROSSCC_X32}"
	export CROSSCXX_X32="ccache ${CROSSCXX_X32}"
	export CROSSCC_X64="ccache ${CROSSCC_X64}"
	export CROSSCXX_X64="ccache ${CROSSCXX_X64}"

	if [ -z "${XDG_CACHE_HOME}" ]; then
		export XDG_CACHE_HOME="${HOME}"/.cache
	fi

	mkdir -p "${XDG_CACHE_HOME}"/ccache
	mkdir -p "${HOME}"/.ccache
fi

build_with_bwrap () {
	if [ "${1}" = "32" ]; then
		BOOTSTRAP_PATH="${BOOTSTRAP_X32}"
	else
		BOOTSTRAP_PATH="${BOOTSTRAP_X64}"
	fi

	if [ "${1}" = "32" ] || [ "${1}" = "64" ]; then
		shift
	fi

	bwrap --ro-bind "${BOOTSTRAP_PATH}" / --dev /dev --ro-bind /sys /sys \
		  --proc /proc --tmpfs /tmp --tmpfs /home --tmpfs /run --tmpfs /var \
		  --tmpfs /mnt --tmpfs /media --bind "${BUILD_DIR}" "${BUILD_DIR}" \
		  --bind-try "${XDG_CACHE_HOME}"/ccache "${XDG_CACHE_HOME}"/ccache \
		  --bind-try "${HOME}"/.ccache "${HOME}"/.ccache \
		  --setenv PATH "/opt/mingw/x86_64/bin:/opt/mingw/i686/bin:/usr/local/bin:/bin:/sbin:/usr/bin:/usr/sbin" \
			"$@"
}

# Dependency checks
if ! command -v git 1>/dev/null; then echo "Please install git"; exit 1; fi
if ! command -v autoconf 1>/dev/null; then echo "Please install autoconf"; exit 1; fi
if ! command -v wget 1>/dev/null; then echo "Please install wget"; exit 1; fi
if ! command -v xz 1>/dev/null; then echo "Please install xz"; exit 1; fi
if ! command -v zip 1>/dev/null; then echo "Please install zip (sudo apt install zip)"; exit 1; fi

# Replace "latest" parameter
if [ "${WINE_VERSION}" = "latest" ] || [ -z "${WINE_VERSION}" ]; then
	WINE_VERSION="$(wget -q -O - "https://raw.githubusercontent.com/wine-mirror/wine/master/VERSION" | tail -c +14)"
fi

# Determine version type
if [ "$(echo "$WINE_VERSION" | cut -d "." -f2 | cut -c1)" = "0" ]; then
	WINE_URL_VERSION=$(echo "$WINE_VERSION" | cut -d "." -f 1).0
else
	WINE_URL_VERSION=$(echo "$WINE_VERSION" | cut -d "." -f 1).x
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}" || exit 1

echo
echo "Downloading source code..."
echo "Preparing Wine for compilation..."
echo

# --------------------------------------------------------------------------
# LOGIC START: Source Code Download
# --------------------------------------------------------------------------

if [ -n "${CUSTOM_SRC_PATH}" ]; then
    # Custom Source Path Logic
	is_url="$(echo "${CUSTOM_SRC_PATH}" | head -c 6)"

	if [ "${is_url}" = "git://" ] || [ "${is_url}" = "https:" ]; then
		git clone "${CUSTOM_SRC_PATH}" wine
	else
		if [ ! -f "${CUSTOM_SRC_PATH}"/configure ]; then
			echo "CUSTOM_SRC_PATH incorrect!"
			exit 1
		fi
		cp -r "${CUSTOM_SRC_PATH}" wine
	fi
	WINE_VERSION="$(cat wine/VERSION | tail -c +14)"
	BUILD_NAME="${WINE_VERSION}"-custom

elif [ "$WINE_BRANCH" = "staging-tkg" ] || [ "$WINE_BRANCH" = "staging-tkg-ntsync" ]; then
    # Wine TKG Logic
	if [ "${EXPERIMENTAL_WOW64}" = "true" ]; then
		git clone https://github.com/Kron4ek/wine-tkg wine -b wow64
	else
		if [ "$WINE_BRANCH" = "staging-tkg" ]; then
			git clone https://github.com/Kron4ek/wine-tkg wine
		else
			git clone https://github.com/Kron4ek/wine-tkg wine -b ntsync
		fi
	fi
	WINE_VERSION="$(cat wine/VERSION | tail -c +14)"
	BUILD_NAME="${WINE_VERSION}"-"${WINE_BRANCH}"

# --------------------------------------------------------------------------
# MODIFIED PROTON BLOCK (KREITINN SOFTWARE)
# --------------------------------------------------------------------------
elif [ "$WINE_BRANCH" = "proton" ]; then
    
    # 1. Definir qué rama intentar clonar
    # Prioridad: Variable MICEWINE_BRANCH > Variable PROTON_BRANCH > master
	if [ -n "${MICEWINE_BRANCH}" ]; then
		TARGET_BRANCH="${MICEWINE_BRANCH}"
	elif [ -n "${PROTON_BRANCH}" ]; then
		TARGET_BRANCH="${PROTON_BRANCH}"
    else
        TARGET_BRANCH="master"
	fi

    echo "Using Repository: KreitinnSoftware/proton-wine"
    echo "Target Branch: ${TARGET_BRANCH}"

    # 2. Intento de clonado con "Fallback"
	if git clone -b "${TARGET_BRANCH}" https://github.com/KreitinnSoftware/proton-wine.git wine; then
		echo "✅ Branch '${TARGET_BRANCH}' downloaded successfully."
	else
		echo "⚠️ Warning: Branch '${TARGET_BRANCH}' not found."
        echo "🔄 Attempting to clone default branch (main/master)..."
		
        if git clone https://github.com/KreitinnSoftware/proton-wine.git wine; then
             echo "✅ Default branch downloaded successfully."
        else
             echo "❌ Fatal Error: Could not clone KreitinnSoftware/proton-wine."
             exit 1
        fi
	fi

    # 3. Establecer nombre de versión
	WINE_VERSION="$(cat wine/VERSION | tail -c +14)-$(git -C wine rev-parse --short HEAD)"
	BUILD_NAME=proton-"${WINE_VERSION}"

# --------------------------------------------------------------------------
# END MODIFIED BLOCK
# --------------------------------------------------------------------------

else
    # Vanilla / Staging / Git Logic
	if [ "${WINE_VERSION}" = "git" ]; then
		git clone https://gitlab.winehq.org/wine/wine.git wine
		BUILD_NAME="${WINE_VERSION}-$(git -C wine rev-parse --short HEAD)"
	else
		BUILD_NAME="${WINE_VERSION}"
		wget -q --show-progress "https://dl.winehq.org/wine/source/${WINE_URL_VERSION}/wine-${WINE_VERSION}.tar.xz"
		tar xf "wine-${WINE_VERSION}.tar.xz"
		mv "wine-${WINE_VERSION}" wine
	fi

	if [ "${WINE_BRANCH}" = "staging" ]; then
		if [ "${WINE_VERSION}" = "git" ]; then
			git clone https://github.com/wine-staging/wine-staging wine-staging-"${WINE_VERSION}"
			upstream_commit="$(cat wine-staging-"${WINE_VERSION}"/staging/upstream-commit | head -c 7)"
			git -C wine checkout "${upstream_commit}"
			BUILD_NAME="${WINE_VERSION}-${upstream_commit}-staging"
		else
			if [ -n "${STAGING_VERSION}" ]; then
				WINE_VERSION="${STAGING_VERSION}"
			fi
			BUILD_NAME="${WINE_VERSION}"-staging
			wget -q --show-progress "https://github.com/wine-staging/wine-staging/archive/v${WINE_VERSION}.tar.gz"
			tar xf v"${WINE_VERSION}".tar.gz
			if [ ! -f v"${WINE_VERSION}".tar.gz ]; then
				git clone https://github.com/wine-staging/wine-staging wine-staging-"${WINE_VERSION}"
			fi
		fi

		if [ -f wine-staging-"${WINE_VERSION}"/patches/patchinstall.sh ]; then
			staging_patcher=("${BUILD_DIR}"/wine-staging-"${WINE_VERSION}"/patches/patchinstall.sh
							DESTDIR="${BUILD_DIR}"/wine)
		else
			staging_patcher=("${BUILD_DIR}"/wine-staging-"${WINE_VERSION}"/staging/patchinstall.py)
		fi

		if [ "${EXPERIMENTAL_WOW64}" = "true" ]; then
			if ! grep Disabled "${BUILD_DIR}"/wine-staging-"${WINE_VERSION}"/patches/ntdll-Syscall_Emulation/definition 1>/dev/null; then
				STAGING_ARGS="--all -W ntdll-Syscall_Emulation"
			fi
		fi

		cd wine || exit 1
		if [ -n "${STAGING_ARGS}" ]; then
			"${staging_patcher[@]}" ${STAGING_ARGS}
		else
			"${staging_patcher[@]}" --all
		fi

		if [ $? -ne 0 ]; then
			echo "Wine-Staging patches were not applied correctly!"
			exit 1
		fi
		cd "${BUILD_DIR}" || exit 1
	fi
fi

if [ ! -d wine ]; then
	clear
	echo "No Wine source code found!"
	echo "Make sure that the correct Wine version is specified."
	exit 1
fi

cd wine || exit 1
dlls/winevulkan/make_vulkan
tools/make_requests
tools/make_specfiles
autoreconf -f
cd "${BUILD_DIR}" || exit 1

if [ "${DO_NOT_COMPILE}" = "true" ]; then
	clear
	echo "DO_NOT_COMPILE is set to true. Exiting."
	exit
fi

if ! command -v bwrap 1>/dev/null; then
	echo "Bubblewrap is not installed!"
	exit 1
fi

if [ ! -d "${BOOTSTRAP_X64}" ] || [ ! -d "${BOOTSTRAP_X32}" ]; then
	clear
	echo "Bootstraps are required for compilation!"
	exit 1
fi

BWRAP64="build_with_bwrap 64"
BWRAP32="build_with_bwrap 32"

export CROSSCC="${CROSSCC_X64}"
export CROSSCXX="${CROSSCXX_X64}"
export CFLAGS="${CFLAGS_X64}"
export CXXFLAGS="${CFLAGS_X64}"
export CROSSCFLAGS="${CROSSCFLAGS_X64}"
export CROSSCXXFLAGS="${CROSSCFLAGS_X64}"

mkdir "${BUILD_DIR}"/build64
cd "${BUILD_DIR}"/build64 || exit
echo "Configuring 64-bit build..."
${BWRAP64} "${BUILD_DIR}"/wine/configure --enable-win64 ${WINE_BUILD_OPTIONS} --prefix "${BUILD_DIR}"/wine-"${BUILD_NAME}"-amd64 || exit 1
echo "Compiling 64-bit build..."
${BWRAP64} make -j$(nproc) install || exit 1

export CROSSCC="${CROSSCC_X32}"
export CROSSCXX="${CROSSCXX_X32}"
export CFLAGS="${CFLAGS_X32}"
export CXXFLAGS="${CFLAGS_X32}"
export CROSSCFLAGS="${CROSSCFLAGS_X32}"
export CROSSCXXFLAGS="${CROSSCFLAGS_X32}"

mkdir "${BUILD_DIR}"/build32-tools
cd "${BUILD_DIR}"/build32-tools || exit
echo "Configuring 32-bit tools..."
PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/lib/i386-linux-gnu/pkgconfig ${BWRAP32} "${BUILD_DIR}"/wine/configure ${WINE_BUILD_OPTIONS} --prefix "${BUILD_DIR}"/wine-"${BUILD_NAME}"-x86 || exit 1
echo "Compiling 32-bit tools..."
${BWRAP32} make -j$(nproc) install || exit 1

export CFLAGS="${CFLAGS_X64}"
export CXXFLAGS="${CFLAGS_X64}"
export CROSSCFLAGS="${CROSSCFLAGS_X64}"
export CROSSCXXFLAGS="${CROSSCFLAGS_X64}"

mkdir "${BUILD_DIR}"/build32
cd "${BUILD_DIR}"/build32 || exit
echo "Configuring 32-bit build (WoW64)..."
PKG_CONFIG_LIBDIR=/usr/lib/i386-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/lib/i386-linux-gnu/pkgconfig ${BWRAP32} "${BUILD_DIR}"/wine/configure --with-wine64="${BUILD_DIR}"/build64 --with-wine-tools="${BUILD_DIR}"/build32-tools ${WINE_BUILD_OPTIONS} --prefix "${BUILD_DIR}"/wine-${BUILD_NAME}-amd64 || exit 1
echo "Compiling 32-bit build (WoW64)..."
${BWRAP32} make -j$(nproc) install || exit 1

echo
echo "Compilation complete"
echo "Creating and compressing archives..."

cd "${BUILD_DIR}" || exit

if touch "${scriptdir}"/write_test; then
	rm -f "${scriptdir}"/write_test
	result_dir="${scriptdir}"
else
	result_dir="${HOME}"
fi

export XZ_OPT="-9"

if [ "${EXPERIMENTAL_WOW64}" = "true" ]; then
	mv wine-${BUILD_NAME}-amd64 wine-${BUILD_NAME}-exp-wow64-amd64
	builds_list="wine-${BUILD_NAME}-exp-wow64-amd64"
else
	builds_list="wine-${BUILD_NAME}-x86 wine-${BUILD_NAME}-amd64"
fi

for build in ${builds_list}; do
	if [ -d "${build}" ]; then
		rm -rf "${build}"/include "${build}"/share/applications "${build}"/share/man

		if [ -f wine/wine-tkg-config.txt ]; then
			cp wine/wine-tkg-config.txt "${build}"
		fi

		if [ "${EXPERIMENTAL_WOW64}" = "true" ]; then
			rm "${build}"/bin/wine "${build}"/bin/wine-preloader
			cp "${build}"/bin/wine64 "${build}"/bin/wine
		fi

        # -------------------------------------------------------------
        # COMPRESIÓN ZIP
        # -------------------------------------------------------------
        echo "Comprimiendo ${build} a formato .tar.xz..."
		tar -Jcf "${build}".tar.xz "${build}"

        echo "Empaquetando dentro de archivo ZIP para facilitar subida..."
        zip "${build}.zip" "${build}.tar.xz"
        
		mv "${build}.zip" "${result_dir}"
        rm "${build}.tar.xz"
	fi
done

rm -rf "${BUILD_DIR}"

echo
echo "Done"
echo "The builds should be in ${result_dir} as .zip files"
