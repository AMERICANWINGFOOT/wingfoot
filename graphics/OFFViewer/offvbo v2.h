/* ============================================================
   offvbo.c ? VBO/IBO helper for QB64 OFF viewer
   Place in: QB64/source/c/parts/core/offvbo.c
   ============================================================ */

#include <stdio.h>
#include <stdlib.h>

/* QB64 includes OpenGL headers differently on Win vs Linux */
#ifdef _WIN32
    #include <windows.h>
    #include <GL/gl.h>
    #include <GL/glext.h>
#else
    #define GL_GLEXT_PROTOTYPES
    #include <GL/gl.h>
    #include <GL/glext.h>
#endif

/* Extension function pointers (mainly needed on Windows) */
#ifdef _WIN32
    static PFNGLGENBUFFERSARBPROC    pglGenBuffers    = NULL;
    static PFNGLBINDBUFFERARBPROC    pglBindBuffer    = NULL;
    static PFNGLBUFFERDATAARBPROC    pglBufferData    = NULL;
    static PFNGLDELETEBUFFERSARBPROC pglDeleteBuffers = NULL;

    static int loadVBOExtensions(void)
    {
        pglGenBuffers    = (PFNGLGENBUFFERSARBPROC)wglGetProcAddress("glGenBuffersARB");
        pglBindBuffer    = (PFNGLBINDBUFFERARBPROC)wglGetProcAddress("glBindBufferARB");
        pglBufferData    = (PFNGLBUFFERDATAARBPROC)wglGetProcAddress("glBufferDataARB");
        pglDeleteBuffers = (PFNGLDELETEBUFFERSARBPROC)wglGetProcAddress("glDeleteBuffersARB");

        if (!pglGenBuffers || !pglBindBuffer || !pglBufferData || !pglDeleteBuffers) {
            fprintf(stderr, "offvbo: Failed to load VBO extensions (ARB)\n");
            return 0;
        }
        return 1;
    }
#else
    /* On Linux/macOS, we can use the core functions directly */
    #define pglGenBuffers    glGenBuffers
    #define pglBindBuffer    glBindBuffer
    #define pglBufferData    glBufferData
    #define pglDeleteBuffers glDeleteBuffers

    static int loadVBOExtensions(void) { return 1; }
#endif

/* VBO / IBO handles */
static GLuint vboVertex = 0;   /* Interleaved: x,y,z, nx,ny,nz */
static GLuint iboIndex  = 0;   /* Triangle indices */
static GLsizei triCount = 0;
static int vboReady = 0;

/* ============================================================
   initVBO - Called once from SUB _GL
   ============================================================ */
void initVBO(float *vx, float *vy, float *vz,
             float *vnx, float *vny, float *vnz,
             long long numV,
             unsigned long long *ti0,
             unsigned long long *ti1,
             unsigned long long *ti2,
             long long numTri_in)
{
    long long i;

    triCount = (GLsizei)numTri_in;

    if (!loadVBOExtensions()) {
        return;
    }

    if (numV <= 0 || numTri_in <= 0) {
        fprintf(stderr, "offvbo: Invalid mesh data (verts=%lld, tris=%lld)\n", numV, numTri_in);
        return;
    }

    /* ---- Create interleaved vertex buffer (position + normal) ---- */
    float *vdata = (float *)malloc(numV * 6 * sizeof(float));
    if (!vdata) {
        fprintf(stderr, "offvbo: Out of memory for vertex data\n");
        return;
    }

    for (i = 0; i < numV; i++) {
        vdata[i*6 + 0] = vx[i];
        vdata[i*6 + 1] = vy[i];
        vdata[i*6 + 2] = vz[i];
        vdata[i*6 + 3] = vnx[i];
        vdata[i*6 + 4] = vny[i];
        vdata[i*6 + 5] = vnz[i];
    }

    /* ---- Create index buffer (convert to unsigned int) ---- */
    unsigned int *idata = (unsigned int *)malloc(numTri_in * 3 * sizeof(unsigned int));
    if (!idata) {
        fprintf(stderr, "offvbo: Out of memory for index data\n");
        free(vdata);
        return;
    }

    for (i = 0; i < numTri_in; i++) {
        idata[i*3 + 0] = (unsigned int)ti0[i];
        idata[i*3 + 1] = (unsigned int)ti1[i];
        idata[i*3 + 2] = (unsigned int)ti2[i];
    }

    /* ---- Upload Vertex Buffer ---- */
    pglGenBuffers(1, &vboVertex);
    pglBindBuffer(GL_ARRAY_BUFFER, vboVertex);
    pglBufferData(GL_ARRAY_BUFFER, numV * 6 * sizeof(float), vdata, GL_STATIC_DRAW);
    pglBindBuffer(GL_ARRAY_BUFFER, 0);

    /* ---- Upload Index Buffer ---- */
    pglGenBuffers(1, &iboIndex);
    pglBindBuffer(GL_ELEMENT_ARRAY_BUFFER, iboIndex);
    pglBufferData(GL_ELEMENT_ARRAY_BUFFER, numTri_in * 3 * sizeof(unsigned int), idata, GL_STATIC_DRAW);
    pglBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);

    free(vdata);
    free(idata);

    vboReady = 1;
    printf("offvbo: Successfully loaded %lld vertices, %lld triangles into VBO/IBO\n", numV, numTri_in);
}

/* ============================================================
   renderMesh - Called every frame from SUB _GL
   ============================================================ */
void renderMesh(int flipNorm)
{
    if (!vboReady) return;

    const GLsizei stride = 6 * sizeof(float);

    pglBindBuffer(GL_ARRAY_BUFFER, vboVertex);

    /* Position */
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(3, GL_FLOAT, stride, (void*)0);

    /* Normal */
    glEnableClientState(GL_NORMAL_ARRAY);
    glNormalPointer(GL_FLOAT, stride, (void*)(3 * sizeof(float)));

    pglBindBuffer(GL_ELEMENT_ARRAY_BUFFER, iboIndex);

    /* Draw the entire mesh in one call */
    glDrawElements(GL_TRIANGLES, triCount * 3, GL_UNSIGNED_INT, (void*)0);

    /* Cleanup */
    pglBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
    pglBindBuffer(GL_ARRAY_BUFFER, 0);

    glDisableClientState(GL_VERTEX_ARRAY);
    glDisableClientState(GL_NORMAL_ARRAY);
}

/* ============================================================
   freeVBO - Cleanup on program exit
   ============================================================ */
void freeVBO(void)
{
    if (vboVertex) {
        pglDeleteBuffers(1, &vboVertex);
        vboVertex = 0;
    }
    if (iboIndex) {
        pglDeleteBuffers(1, &iboIndex);
        iboIndex = 0;
    }
    vboReady = 0;
    triCount = 0;
}

