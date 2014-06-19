!******************************************************************************
! Routines to set up the MPI routines and allocate dynamic arrays
!******************************************************************************

MODULE mpi_routines

  USE shared_data
  IMPLICIT NONE

  PRIVATE
  PUBLIC :: mpi_initialise, mpi_close

  REAL(dbl) :: start_time, end_time

CONTAINS

  !****************************************************************************
  ! Start up the MPI layer, allocate arrays and set up MPI types
  !****************************************************************************

  SUBROUTINE mpi_initialise
 
    INTEGER, PARAMETER :: ng = 1
    LOGICAL, PARAMETER :: allow_cpu_reduce = .FALSE.
    INTEGER :: dims(c_ndims), icoord, old_comm, ierr
    LOGICAL :: periods(c_ndims), reorder, reset
    INTEGER :: starts(c_ndims), sizes(c_ndims), subsizes(c_ndims)
    INTEGER :: ix, iy
    INTEGER :: nx0, ny0
    INTEGER :: nxp, nyp
    INTEGER :: nxsplit, nysplit
    INTEGER :: x_coords, y_coords
    INTEGER :: area, minarea
    INTEGER :: ranges(3,1), nproc_orig, oldgroup, newgroup

    CALL MPI_COMM_SIZE(MPI_COMM_WORLD, nproc, errcode)

    nproc_orig = nproc

    IF (nx_global < ng .OR. ny_global < ng) THEN
      IF (rank == 0) THEN
        PRINT*,'*** ERROR ***'
        PRINT*,'Simulation domain is too small.'
        PRINT*,'There must be at least ', ng, ' cells in each direction.'
      ENDIF
      CALL MPI_ABORT(MPI_COMM_WORLD, errcode, ierr)
    ENDIF

    reset = .FALSE.
    IF (MAX(nprocx,1) * MAX(nprocy,1) > nproc) THEN
      reset = .TRUE.
    ELSE IF (nprocx * nprocy > 0) THEN
      ! Sanity check
      nxsplit = nx_global / nprocx
      nysplit = ny_global / nprocy
      IF (nxsplit < ng .OR. nysplit < ng) &
          reset = .TRUE.
    ENDIF

    IF (reset) THEN
      IF (rank == 0) THEN
        PRINT *, 'Unable to use requested processor subdivision. Using ' &
            // 'default division.'
      ENDIF
      nprocx = 0
      nprocy = 0
    ENDIF

    IF (nprocx * nprocy == 0) THEN
      DO WHILE (nproc > 1)
        ! Find the processor split which minimizes surface area of
        ! the resulting domain

        minarea = nx_global + ny_global

        DO ix = 1, nproc
          iy = nproc / ix
          IF (ix * iy /= nproc) CYCLE

          nxsplit = nx_global / ix
          nysplit = ny_global / iy
          ! Actual domain must be bigger than the number of ghostcells
          IF (nxsplit < ng .OR. nysplit < ng) CYCLE

          area = nxsplit + nysplit
          IF (area < minarea) THEN
            nprocx = ix
            nprocy = iy
            minarea = area
          ENDIF
        ENDDO

        IF (nprocx > 0) EXIT

        ! If we get here then no suitable split could be found. Decrease the
        ! number of processors and try again.

        nproc = nproc - 1
      ENDDO
    ENDIF

    IF (nproc_orig /= nproc) THEN
      IF (.NOT.allow_cpu_reduce) THEN
        IF (rank == 0) THEN
          PRINT*,'*** ERROR ***'
          PRINT*,'Cannot split the domain using the requested number of CPUs.'
          PRINT*,'Try reducing the number of CPUs to ', nproc
        ENDIF
        CALL MPI_ABORT(MPI_COMM_WORLD, errcode, ierr)
        STOP
      ENDIF
      IF (rank == 0) THEN
        PRINT*,'*** WARNING ***'
        PRINT*,'Cannot split the domain using the requested number of CPUs.'
        PRINT*,'Reducing the number of CPUs to ', nproc
      ENDIF
      ranges(1,1) = nproc
      ranges(2,1) = nproc_orig - 1
      ranges(3,1) = 1
      old_comm = comm
      CALL MPI_COMM_GROUP(old_comm, oldgroup, errcode)
      CALL MPI_GROUP_RANGE_EXCL(oldgroup, 1, ranges, newgroup, errcode)
      CALL MPI_COMM_CREATE(old_comm, newgroup, comm, errcode)
      IF (comm == MPI_COMM_NULL) THEN
        CALL MPI_FINALIZE(errcode)
        STOP
      ENDIF
      CALL MPI_GROUP_FREE(oldgroup, errcode)
      CALL MPI_GROUP_FREE(newgroup, errcode)
      CALL MPI_COMM_FREE(old_comm, errcode)
    ENDIF

    dims = (/nprocy, nprocx/)
    CALL MPI_DIMS_CREATE(nproc, c_ndims, dims, errcode)

    IF (PRODUCT(MAX(dims, 1)) > nproc) THEN
      dims = 0
      IF (rank == 0) THEN
        PRINT*, 'Too many processors requested in override.'
        PRINT*, 'Reverting to automatic decomposition.'
        PRINT*, '******************************************'
        PRINT*
      END IF
    END IF

    CALL MPI_DIMS_CREATE(nproc, c_ndims, dims, errcode)

    nprocx = dims(c_ndims  )
    nprocy = dims(c_ndims-1)

    ALLOCATE(cell_nx_mins(0:nprocx-1), cell_nx_maxs(0:nprocx-1))
    ALLOCATE(cell_ny_mins(0:nprocy-1), cell_ny_maxs(0:nprocy-1))

    periods = .TRUE.
    reorder = .TRUE.

    IF (xbc_min == BC_OTHER) periods(c_ndims  ) = .FALSE.
    IF (xbc_max == BC_OTHER) periods(c_ndims  ) = .FALSE.
    IF (ybc_min == BC_OTHER) periods(c_ndims-1) = .FALSE.
    IF (ybc_max == BC_OTHER) periods(c_ndims-1) = .FALSE.

    IF (xbc_min == BC_OPEN) periods(c_ndims  ) = .FALSE.
    IF (xbc_max == BC_OPEN) periods(c_ndims  ) = .FALSE.
    IF (ybc_min == BC_OPEN) periods(c_ndims-1) = .FALSE.
    IF (ybc_max == BC_OPEN) periods(c_ndims-1) = .FALSE.

    CALL MPI_CART_CREATE(MPI_COMM_WORLD, c_ndims, dims, periods, reorder, &
        comm, errcode)

    CALL MPI_COMM_RANK(comm, rank, errcode)
    CALL MPI_CART_COORDS(comm, rank, c_ndims, coordinates, errcode)
    CALL MPI_CART_SHIFT(comm, c_ndims-1, 1, proc_x_min, proc_x_max, errcode)
    CALL MPI_CART_SHIFT(comm, c_ndims-2, 1, proc_y_min, proc_y_max, errcode)

    x_coords = coordinates(c_ndims  )
    y_coords = coordinates(c_ndims-1)

    ! Create the subarray for this problem: subtype decribes where this
    ! process's data fits into the global picture.

    nx0 = nx_global / nprocx
    ny0 = ny_global / nprocy

    ! If the number of gridpoints cannot be exactly subdivided then fix
    ! The first nxp processors have nx0 grid points
    ! The remaining processors have nx0+1 grid points
    IF (nx0 * nprocx /= nx_global) THEN
      nxp = (nx0 + 1) * nprocx - nx_global
    ELSE
      nxp = nprocx
    END IF

    IF (ny0 * nprocy /= ny_global) THEN
      nyp = (ny0 + 1) * nprocy - ny_global
    ELSE
      nyp = nprocy
    END IF

    ! Set up the starting point for my subgrid (assumes arrays start at 0)

    DO icoord = 0, nxp - 1
      cell_nx_mins(icoord) = icoord * nx0 + 1
      cell_nx_maxs(icoord) = (icoord + 1) * nx0
    END DO
    DO icoord = nxp, nprocx - 1
      cell_nx_mins(icoord) = nxp * nx0 + (icoord - nxp) * (nx0 + 1) + 1
      cell_nx_maxs(icoord) = nxp * nx0 + (icoord - nxp + 1) * (nx0 + 1)
    END DO

    DO icoord = 0, nyp - 1
      cell_ny_mins(icoord) = icoord * ny0 + 1
      cell_ny_maxs(icoord) = (icoord + 1) * ny0
    END DO
    DO icoord = nyp, nprocy - 1
      cell_ny_mins(icoord) = nyp * ny0 + (icoord - nyp) * (ny0 + 1) + 1
      cell_ny_maxs(icoord) = nyp * ny0 + (icoord - nyp + 1) * (ny0 + 1)
    END DO

    n_global_min(1) = cell_nx_mins(x_coords) - 1
    n_global_max(1) = cell_nx_maxs(x_coords)

    n_global_min(2) = cell_ny_mins(y_coords) - 1
    n_global_max(2) = cell_ny_maxs(y_coords)

    nx = n_global_max(1) - n_global_min(1)
    ny = n_global_max(2) - n_global_min(2)

    ! The grid sizes
    subsizes = (/ nx+1, ny+1 /)
    sizes = (/ nx_global+1, ny_global+1 /)
    starts = n_global_min

    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, subtype, errcode)

    CALL MPI_TYPE_COMMIT(subtype, errcode)

    ALLOCATE(energy(-1:nx+2, -1:ny+2))
    ALLOCATE(p_visc(-1:nx+2, -1:ny+2))
    ALLOCATE(rho(-1:nx+2, -1:ny+2))
    ALLOCATE(vx (-2:nx+2, -2:ny+2))
    ALLOCATE(vy (-2:nx+2, -2:ny+2))
    ALLOCATE(vz (-2:nx+2, -2:ny+2))
    ALLOCATE(vx1(-2:nx+2, -2:ny+2))
    ALLOCATE(vy1(-2:nx+2, -2:ny+2))
    ALLOCATE(vz1(-2:nx+2, -2:ny+2))
    ALLOCATE(bx (-2:nx+2, -1:ny+2))
    ALLOCATE(by (-1:nx+2, -2:ny+2))
    ALLOCATE(bz (-1:nx+2, -1:ny+2))
    ALLOCATE(eta(-1:nx+2, -1:ny+2))
    IF (rke) ALLOCATE(delta_ke(-1:nx+2, -1:ny+2))
    ALLOCATE(lambda_i(0:nx, 0:ny))

    ! Shocked and resistive need to be larger to allow offset = 4 in shock_test
    ALLOCATE(cv(-1:nx+2, -1:ny+2), cv1(-1:nx+2, -1:ny+2))
    ALLOCATE(xc(-1:nx+2), xb(-2:nx+2), dxc(-1:nx+1), dxb(-1:nx+2))
    ALLOCATE(yc(-1:ny+2), yb(-2:ny+2), dyc(-1:ny+1), dyb(-1:ny+2))
    ALLOCATE(grav(-1:ny+2))
    ALLOCATE(jx_r(0:nx+1, 0:ny+1))
    ALLOCATE(jy_r(0:nx+1, 0:ny+1))
    ALLOCATE(jz_r(0:nx+1, 0:ny+1))

    ALLOCATE(xb_global(-2:nx_global+2))
    ALLOCATE(yb_global(-2:ny_global+2))

    IF (rank == 0) start_time = MPI_WTIME()

    p_visc = 0.0_num
    eta = 0.0_num

    CALL mpi_create_types

  END SUBROUTINE mpi_initialise



  !****************************************************************************
  ! Shutdown the MPI layer, deallocate arrays and set up timing info
  !****************************************************************************

  SUBROUTINE mpi_close

    INTEGER :: seconds, minutes, hours, total

    IF (rank == 0) THEN
      end_time = MPI_WTIME()
      total = INT(end_time - start_time)
      seconds = MOD(total, 60)
      minutes = MOD(total / 60, 60)
      hours = total / 3600
      WRITE(stat_unit,*)
      WRITE(stat_unit,'(''runtime = '', i4, ''h '', i2, ''m '', i2, ''s on '', &
          & i4, '' process elements.'')') hours, minutes, seconds, nproc
    END IF

    CALL MPI_BARRIER(comm, errcode)

    CALL mpi_destroy_types

    DEALLOCATE(rho, energy)
    DEALLOCATE(vx, vy, vz)
    DEALLOCATE(vx1, vy1, vz1)
    DEALLOCATE(bx, by, bz)
    DEALLOCATE(p_visc)
    DEALLOCATE(eta)
    DEALLOCATE(cv, cv1)
    DEALLOCATE(xc, xb, dxb, dxc)
    DEALLOCATE(yc, yb, dyb, dyc)
    DEALLOCATE(grav)
    DEALLOCATE(jx_r, jy_r, jz_r)
    DEALLOCATE(xb_global, yb_global)
    DEALLOCATE(cell_nx_mins, cell_nx_maxs)
    DEALLOCATE(cell_ny_mins, cell_ny_maxs)
    DEALLOCATE(lambda_i)

    IF (ALLOCATED(xi_n)) DEALLOCATE(xi_n)
    IF (ALLOCATED(delta_ke)) DEALLOCATE(delta_ke)
    IF (ALLOCATED(eta_perp)) DEALLOCATE(eta_perp)
    IF (ALLOCATED(parallel_current)) DEALLOCATE(parallel_current)
    IF (ALLOCATED(perp_current)) DEALLOCATE(perp_current)

  END SUBROUTINE mpi_close



  SUBROUTINE mpi_create_types

    INTEGER :: sizes(c_ndims), subsizes(c_ndims), starts(c_ndims)
    INTEGER :: local_dims(c_ndims)
    INTEGER :: idir, vdir, mpitype
    INTEGER, PARAMETER :: ng = 2 ! Number of ghost cells

    local_dims = (/ nx, ny /)

    ! MPI types for cell-centred variables

    ! Cell-centred array dimensions
    sizes = local_dims + 2 * ng

    ! ng cells, 1d slice of cell-centred variable

    idir = 1
    subsizes = sizes
    subsizes(idir) = ng
    starts = 0

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    cell_xface = mpitype

    idir = 2
    subsizes = sizes
    subsizes(idir) = ng

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    cell_yface = mpitype

    ! MPI types for node-centred variables

    ! Node-centred array dimensions
    sizes = local_dims + 2 * ng + 1

    ! ng cells, 1d slice of node-centred variable

    idir = 1
    subsizes = sizes
    subsizes(idir) = ng
    starts = 0

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    node_xface = mpitype

    idir = 2
    subsizes = sizes
    subsizes(idir) = ng

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    node_yface = mpitype

    ! ng+1 cells, 1d slice of node-centred variable

    idir = 1
    subsizes = sizes
    subsizes(idir) = ng + 1

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    node_xface1 = mpitype

    idir = 2
    subsizes = sizes
    subsizes(idir) = ng + 1

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    node_yface1 = mpitype

    ! MPI types for Bx-sized variables
    vdir = 1

    ! Bx-sized array dimensions
    sizes = local_dims + 2 * ng
    sizes(vdir) = sizes(vdir) + 1

    ! ng cells, 1d slice of Bx-sized variable

    idir = 1
    subsizes = sizes
    subsizes(idir) = ng
    starts = 0

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    bx_xface = mpitype

    idir = 2
    subsizes = sizes
    subsizes(idir) = ng

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    bx_yface = mpitype

    ! ng+1 cells, 1d slice of Bx-sized variable

    idir = vdir
    subsizes = sizes
    subsizes(idir) = ng + 1

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    bx_xface1 = mpitype

    ! MPI types for By-sized variables
    vdir = 2

    ! By-sized array dimensions
    sizes = local_dims + 2 * ng
    sizes(vdir) = sizes(vdir) + 1

    ! ng cells, 1d slice of By-sized variable

    idir = 1
    subsizes = sizes
    subsizes(idir) = ng
    starts = 0

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    by_xface = mpitype

    idir = 2
    subsizes = sizes
    subsizes(idir) = ng

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    by_yface = mpitype

    ! ng+1 cells, 1d slice of By-sized variable

    idir = vdir
    subsizes = sizes
    subsizes(idir) = ng + 1

    mpitype = MPI_DATATYPE_NULL
    CALL MPI_TYPE_CREATE_SUBARRAY(c_ndims, sizes, subsizes, starts, &
        MPI_ORDER_FORTRAN, mpireal, mpitype, errcode)
    CALL MPI_TYPE_COMMIT(mpitype, errcode)

    by_yface1 = mpitype

    ! MPI types for Bz-sized variables - same as cell-centred variable in 2d

    bz_xface = cell_xface
    bz_yface = cell_yface

  END SUBROUTINE mpi_create_types



  SUBROUTINE mpi_destroy_types

    CALL MPI_TYPE_FREE(cell_xface, errcode)
    CALL MPI_TYPE_FREE(cell_yface, errcode)
    CALL MPI_TYPE_FREE(node_xface, errcode)
    CALL MPI_TYPE_FREE(node_yface, errcode)
    CALL MPI_TYPE_FREE(node_xface1, errcode)
    CALL MPI_TYPE_FREE(node_yface1, errcode)
    CALL MPI_TYPE_FREE(bx_xface, errcode)
    CALL MPI_TYPE_FREE(bx_yface, errcode)
    CALL MPI_TYPE_FREE(by_xface, errcode)
    CALL MPI_TYPE_FREE(by_yface, errcode)
    CALL MPI_TYPE_FREE(bx_xface1, errcode)
    CALL MPI_TYPE_FREE(by_yface1, errcode)

  END SUBROUTINE mpi_destroy_types

END MODULE mpi_routines
