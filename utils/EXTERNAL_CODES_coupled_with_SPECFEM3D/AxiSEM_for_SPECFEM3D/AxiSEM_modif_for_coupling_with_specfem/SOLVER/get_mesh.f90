!
!    Copyright 2013, Tarje Nissen-Meyer, Alexandre Fournier, Martin van Driel
!                    Simon Stähler, Kasra Hosseini, Stefanie Hempel
!
!    This file is part of AxiSEM.
!    It is distributed from the webpage <http://www.axisem.info>
!
!    AxiSEM is free software: you can redistribute it and/or modify
!    it under the terms of the GNU General Public License as published by
!    the Free Software Foundation, either version 3 of the License, or
!    (at your option) any later version.
!
!    AxiSEM is distributed in the hope that it will be useful,
!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!    GNU General Public License for more details.
!
!    You should have received a copy of the GNU General Public License
!    along with AxiSEM.  If not, see <http://www.gnu.org/licenses/>.
!

!=========================================================================================
module get_mesh

  ! This module reads in mesh properties from the mesher (databases meshdb.dat),
  ! and allocates related memory.
  ! The database contains at the global level:
  !    elemental control nodes, element type.
  ! at the solid/fluid level:
  !    mapping from solid/fluid to global element numbers, global numbering
  !    (for solid/fluid subdomains only), solid-fluid boundary element mapping.
  !    solid/fluid message-passing mapping arrays and message size indicators;
  ! and general background model information, time step & period, axial arrays.

  use global_parameters
  use data_io,              only : verbose

  implicit none

  public :: read_db
  public :: compute_coordinates_mesh
  private

contains

!-----------------------------------------------------------------------------------------
subroutine read_db
  ! Read in the database generated by the mesher. File names are
  ! meshdb.dat0000, meshdb.dat0001, etc. for nproc-1 processor jobs.
  ! These databases must stem from the same meshing as mesh_params.h !!

  use data_mesh
  use data_comm
  use data_proc
  use data_time
  use data_io,            only : do_anel, ibeg, iend, jbeg, jend, dump_type
  use commun,             only : barrier, psum, pmax, pmin
  use background_models,  only : model_is_ani, model_is_anelastic, get_ext_disc, &
                                 override_ext_q

  integer             :: iptp, ipsrc, imsg, iel, idom, i, ioerr
  character(len=120)  :: dbname
  integer             :: globnaxel, globnaxel_solid, globnaxel_fluid

  dbname = 'Mesh/meshdb.dat'//appmynum

  call barrier
  do i=0, nproc-1
     if (mynum==i) then
        if (verbose > 1) write(6,*)'  ', procstrg, 'opening database ', trim(dbname)
        open(1000+mynum, file=trim(dbname), FORM="UNFORMATTED", &
                             STATUS="OLD", POSITION="REWIND", IOSTAT=ioerr)
        if (ioerr/=0) then
           write(6,*) 'Could not open mesh file ', trim(dbname)
           stop
        endif
     endif
     call flush(6)
     call barrier
  enddo

  if (lpr .and. verbose > 1) write(6,*) &
        '  Reading databases: see processor output for details.'

  ! Read all the parameters formerly in mesh_params.h
  call read_mesh_basics(1000+mynum)

  call read_mesh_advanced(1000+mynum)

  ! npol is now defined, so we can set iend
  if (trim(dump_type) == 'displ_only') then
     ibeg = 0
     iend = npol
     jbeg = 0
     jend = npol
  endif

  !!!!!!!!!!!! BACKGROUND MODEL !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  ! General numerical input/output parameters
  if (verbose > 1) write(69,*)'reading numerical parameters...'
  read(1000+mynum) pts_wavelngth,period,courant,deltat

  if (verbose > 1) then
     write(69,*)
     write(69,*)'General numerical input/output parameters==================='
     write(69,*)'  pts/wavelngth=',pts_wavelngth
     write(69,*)'  period [s]=',period
     write(69,*)'  courant=',courant
     write(69,*)'  deltat [s]=',deltat
     write(69,*)
  endif

  if (lpr) then
     write(6,*)
     write(6,*)'  General numerical input/output parameters================'
     write(6,*)'    grid pts/wavelngth =',pts_wavelngth
     write(6,*)'    source period [s]  =',period
     write(6,*)'    courant number     =',courant
     write(6,*)'    time step [s]      =',deltat
  endif

  ! Background model
  bkgrdmodel = ''
  if (verbose > 1) write(69,*)'reading background model info...'
  read(1000+mynum) bkgrdmodel(1:lfbkgrdmodel)
  read(1000+mynum) override_ext_q

  if (verbose > 1.and.lpr) print *, '  Background model: ', trim(bkgrdmodel)

  if (trim(bkgrdmodel)=='external') then
     if (verbose > 1.and.lpr) write(69,*)'reading external velocity model file...'
     call get_ext_disc('./external_model.bm')
  endif

  read(1000+mynum) router, have_fluid
  if (verbose > 1.and.lpr) write(*,"(A,F12.2)") 'Model has radius ', router, ' m'
  allocate(discont(ndisc), solid_domain(ndisc), idom_fluid(ndisc))
  do idom=1, ndisc
     read(1000+mynum) discont(idom), solid_domain(idom), idom_fluid(idom)
  enddo

  if (do_anel) then
     if (model_is_anelastic(bkgrdmodel)) then
        anel_true = .true.
     else
        print *, 'ERROR: viscoelastic attenuation set in inparam file, but'
        print *, '       backgroundmodel ', trim(bkgrdmodel), ' is elastic only.'
        stop 2
     endif
  else
     anel_true = .false.
  endif

  read(1000+mynum) rmin, minh_ic, maxh_ic, maxh_icb
  if (verbose > 1) then
     write(69,*)
     write(69,*) 'Background model============================================'
     write(69,*) '  bkgrdmodel          = ', bkgrdmodel(1:lfbkgrdmodel)
     write(69,*) '  router [m]          = ', router
     write(69,*) '  have_fluid          = ', have_fluid
     write(69,*) '  anel_true           = ', anel_true
  endif

  if (lpr) then
     write(6,*)
     write(6,*)'  Background model========================================='
     write(6,*)'    bkgrdmodel = ', bkgrdmodel(1:lfbkgrdmodel)
     write(6,*)'    radius [m] = ', router
     write(6,*)'    have_fluid = ', have_fluid
  endif

  ! Min/max grid spacing
  read(1000+mynum)hmin_glob,hmax_glob
  read(1000+mynum)min_distance_dim,min_distance_nondim

  if (verbose > 1) then
     write(69,*)
     write(69,*)'Min/max grid spacing========================================'
     write(69,*)'  hmin          [m]   : ', hmin_glob
     write(69,*)'  hmax          [m]   : ', hmax_glob
     write(69,*)'  min_distance_dim [m]: ', min_distance_dim
     write(69,*)'  min_distance_nondim : ', min_distance_nondim
  endif

  hmin_glob = pmax(hmin_glob)
  hmax_glob = pmax(hmax_glob)

  min_distance_dim=pmin(min_distance_dim)
  if (lpr) then
     write(6,*)
     write(6,*)'  Min/max grid spacing====================================='
     write(6,*)'    hmin (global) [m]   : ', hmin_glob
     write(6,*)'    hmax (global) [m]   : ', hmax_glob
     write(6,*)'    min_distance_dim [m]: ', min_distance_dim
     write(6,*)
  endif

  ! critical ratios h/v min/max and locations
  read(1000+mynum) char_time_max,      char_time_max_globel
  read(1000+mynum) char_time_max_rad,  char_time_max_theta
  read(1000+mynum) char_time_min,      char_time_min_globel
  read(1000+mynum) char_time_min_rad,  char_time_min_theta

  if (verbose > 1) then
     write(69,*)
     write(69,*)'critical ratios max(h/v) and locations=================='
     write(69,*)'  max. charact. time [s]  :', char_time_max
     write(69,*)'  correspond. radius [m]  :', char_time_max_rad*router
     write(69,*)'  correspond. theta [deg] :', char_time_max_theta
     write(69,*)
     write(69,*)'critical ratios min(h/v) and locations=================='
     write(69,*)'  min. charact. time [s] : ', char_time_min
     write(69,*)'  correspond. radius [m] : ', char_time_min_rad*router
     write(69,*)'  correspond. theta [deg]: ', char_time_min_theta
     write(69,*)
  endif

  ! Axial element arrays
  read(1000+mynum) naxel, naxel_solid, naxel_fluid

  if (verbose > 1) write(69,*) 'Axial elements (glob,sol,flu): ', &
                                naxel, naxel_solid, naxel_fluid

  if (lpr) write(6,*)'  Axialogy================================================='

  call barrier
  do i=0, nproc-1
     call barrier
     if (mynum==i) then
        if (verbose > 1) then
           write(6,11) procstrg, naxel, naxel_solid, naxel_fluid
           write(69,*) '      number of total axial elements:', naxel
           write(69,*) '      number of solid axial elements:', naxel_solid
           write(69,*) '      number of fluid axial elements:', naxel_fluid
        endif
     endif
     call barrier
  enddo

11 format('     ',a8,'has',i6,' axial elements (',i6,' solid,',i4,' fluid)')

  globnaxel = int(psum(real(naxel,kind=realkind)))
  globnaxel_solid = int(psum(real(naxel_solid,kind=realkind)))
  globnaxel_fluid = int(psum(real(naxel_fluid,kind=realkind)))

  if (lpr) then
     write(6,*)
     write(6,*) '    Global total axial elements:', globnaxel
     write(6,*) '    Global solid axial elements:', globnaxel_solid
     write(6,*) '    Global fluid axial elements:', globnaxel_fluid
     write(6,*)
  endif

  call read_mesh_axel(1000+mynum)

  ! mask s-coordinate of axial elements identically to zero
  if (lpr .and. verbose > 1) write(6,*)'  setting s coordinate identical to zero along axis...'
  do iel=1, naxel
    crd_nodes(lnods(ax_el(iel),1),1) = zero
    crd_nodes(lnods(ax_el(iel),7),1) = zero
    crd_nodes(lnods(ax_el(iel),8),1) = zero
  enddo

  if (verbose > 1) write(69,*) 'reading communication info...'

  ! SOLID message passing SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS
  read(1000+mynum) sizerecv_solid
  !if (verbose > 1) write(69,*) 'number of solid messages received:', sizerecv_solid
  if (verbose > 1) write(69,*) 'number of solid messages:', sizerecv_solid

  if ( sizerecv_solid > 0) then
     allocate(listrecv_solid(1:sizerecv_solid))
     listrecv_solid(:) = -1

     allocate(sizemsgrecv_solid(1:sizerecv_solid))
     sizemsgrecv_solid(:) = 0

     read(1000+mynum) listrecv_solid(:)
     read(1000+mynum) sizemsgrecv_solid(:)
     sizemsgrecvmax_solid = maxval(sizemsgrecv_solid(:))

     if (verbose > 1) write(69,*) 'max size of solid messages received:', &
                                   sizemsgrecvmax_solid

     allocate(glocal_index_msg_recv_solid(1:sizemsgrecvmax_solid,1:sizerecv_solid))
     glocal_index_msg_recv_solid(:,:) = 0

     allocate(buffr_solid(1:sizemsgrecvmax_solid,1:3))
     buffr_solid = 0

     ! fill buffer list with arrays of appropriate size
     do imsg = 1, sizerecv_solid
         call buffr_all_solid%append(buffr_solid(1:sizemsgrecv_solid(imsg),:))
     enddo

     do imsg = 1, sizerecv_solid
        ipsrc = listrecv_solid(imsg)
        do iptp = 1, sizemsgrecv_solid(imsg)
           read(1000+mynum) glocal_index_msg_recv_solid(iptp,imsg)
        enddo
     enddo

     sizesend_solid = sizerecv_solid
     allocate(listsend_solid(1:sizesend_solid))
     listsend_solid = listrecv_solid
     allocate(sizemsgsend_solid(1:sizesend_solid))
     sizemsgsend_solid = sizemsgrecv_solid
     sizemsgsendmax_solid = sizemsgrecvmax_solid
     allocate(glocal_index_msg_send_solid(1:sizemsgsendmax_solid,1:sizesend_solid))
     glocal_index_msg_send_solid = glocal_index_msg_recv_solid

     allocate(buffs_solid(1:sizemsgsendmax_solid,1:3))
     buffs_solid = 0

     ! fill buffer list with arrays of appropriate size
     do imsg = 1, sizesend_solid
         call buffs_all_solid%append(buffs_solid(1:sizemsgsend_solid(imsg),:))
     enddo

     allocate(recv_request_solid(1:sizerecv_solid))
     allocate(send_request_solid(1:sizesend_solid))

  endif

  ! FLUID message passing FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
  if (have_fluid) then

     read(1000+mynum) sizerecv_fluid

     if (verbose > 1) write(69,*)'number of fluid messages received:', sizerecv_fluid

     if ( sizerecv_fluid > 0) then
        allocate(listrecv_fluid(1:sizerecv_fluid))
        listrecv_fluid(:) = -1

        allocate(sizemsgrecv_fluid(1:sizerecv_fluid))
        sizemsgrecv_fluid(:) = 0

        read(1000+mynum) listrecv_fluid(:)
        read(1000+mynum) sizemsgrecv_fluid(:)
        sizemsgrecvmax_fluid = maxval(sizemsgrecv_fluid(:))

        if (verbose > 1) write(69,*) 'max size of fluid messages received:', &
                                      sizemsgrecvmax_fluid

        allocate(glocal_index_msg_recv_fluid(1:sizemsgrecvmax_fluid,1:sizerecv_fluid))
        glocal_index_msg_recv_fluid(:,:) = 0
        allocate(buffr_fluid(1:sizemsgrecvmax_fluid,1))
        buffr_fluid = 0
        ! fill buffer list with arrays of appropriate size
        do imsg = 1, sizerecv_fluid
            call buffr_all_fluid%append(buffr_fluid(1:sizemsgrecv_fluid(imsg),:))
        enddo

        do imsg = 1, sizerecv_fluid
           ipsrc = listrecv_fluid(imsg)
           do iptp = 1, sizemsgrecv_fluid(imsg)
              read(1000+mynum) glocal_index_msg_recv_fluid(iptp,imsg)
           enddo
        enddo

        sizesend_fluid = sizerecv_fluid
        allocate(listsend_fluid(1:sizesend_fluid))
        listsend_fluid = listrecv_fluid
        allocate(sizemsgsend_fluid(1:sizesend_fluid))
        sizemsgsend_fluid = sizemsgrecv_fluid
        sizemsgsendmax_fluid = sizemsgrecvmax_fluid
        allocate(glocal_index_msg_send_fluid(1:sizemsgsendmax_fluid,1:sizesend_fluid))
        glocal_index_msg_send_fluid = glocal_index_msg_recv_fluid

        allocate(buffs_fluid(1:sizemsgsendmax_fluid,1))
        buffs_fluid = 0
        ! fill buffer list with arrays of appropriate size
        do imsg = 1, sizesend_fluid
            call buffs_all_fluid%append(buffs_fluid(1:sizemsgsend_fluid(imsg),:))
        enddo

        allocate(recv_request_fluid(1:sizerecv_fluid))
        allocate(send_request_fluid(1:sizesend_fluid))

     endif

  endif ! have_fluid

  if (verbose > 1) write(69,*) 'Successfully read parallel database'

  ! Allocate mesh arrays
  allocate(mean_rad_colat_solid(nel_solid,2))
  allocate(mean_rad_colat_fluid(nel_fluid,2))

  ! Allocate arrays from data_mesh_preloop (only needed before the time loop),
  ! i.e. to be deallocated before the loop
  allocate(north(1:nelem), axis(1:nelem))


  do i=0, nproc-1
     call barrier
     if (mynum==i) then
        if (verbose > 1) write(6,*) '  ', procstrg,'closing database ', trim(dbname)
        call flush(6)
        if (verbose > 1) write(69,*) 'Closed the database'
        close(1000+mynum)
     endif
     call barrier
  enddo
  call flush(6)
  if (lpr) write(6,*)

end subroutine read_db
!-----------------------------------------------------------------------------------------

!-----------------------------------------------------------------------------------------
elemental subroutine compute_coordinates_mesh(s,z,ielem,inode)
  ! Output s,z are the physical coordinates defined at
  ! serendipity nodes inode (between 1 and 8 usually)
  ! for (global) element ielem

  use data_mesh, only            : crd_nodes, lnods
  integer, intent(in)           :: ielem, inode
  real(kind=dp)   , intent(out) :: s,z

  s = crd_nodes(lnods(ielem,inode),1)
  z = crd_nodes(lnods(ielem,inode),2)

end subroutine compute_coordinates_mesh
!-----------------------------------------------------------------------------------------

end module get_mesh
!=========================================================================================
