!**********************************************************************
! Copyright 1998,1999,2000,2001,2002,2005,2007,2008,2009,2010         *
! Andreas Stohl, Petra Seibert, A. Frank, Gerhard Wotawa,             *
! Caroline Forster, Sabine Eckhardt, John Burkhart, Harald Sodemann   *
!                                                                     *
! This file is part of FLEXPART.                                      *
!                                                                     *
! FLEXPART is free software: you can redistribute it and/or modify    *
! it under the terms of the GNU General Public License as published by*
! the Free Software Foundation, either version 3 of the License, or   *
! (at your option) any later version.                                 *
!                                                                     *
! FLEXPART is distributed in the hope that it will be useful,         *
! but WITHOUT ANY WARRANTY; without even the implied warranty of      *
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the       *
! GNU General Public License for more details.                        *
!                                                                     *
! You should have received a copy of the GNU General Public License   *
! along with FLEXPART.  If not, see <http://www.gnu.org/licenses/>.   *
!**********************************************************************

subroutine verttransform_gfs(n,uuh,vvh,wwh,pvh)
!                      i  i   i   i   i
!*****************************************************************************
!                                                                            *
!     This subroutine transforms temperature, dew point temperature and      *
!     wind components from eta to meter coordinates.                         *
!     The vertical wind component is transformed from Pa/s to m/s using      *
!     the conversion factor pinmconv.                                        *
!     In addition, this routine calculates vertical density gradients        *
!     needed for the parameterization of the turbulent velocities.           *
!                                                                            *
!     Author: A. Stohl, G. Wotawa                                            *
!                                                                            *
!     12 August 1996                                                         *
!     Update: 16 January 1998                                                *
!                                                                            *
!     Major update: 17 February 1999                                         *
!     by G. Wotawa                                                           *
!     CHANGE 17/11/2005 Caroline Forster, NCEP GFS version                   *
!                                                                            *
!   - Vertical levels for u, v and w are put together                        *
!   - Slope correction for vertical velocity: Modification of calculation    *
!     procedure                                                              *
!                                                                            *
!*****************************************************************************
!  Changes, Bernd C. Krueger, Feb. 2001:
!    Variables tth and qvh (on eta coordinates) from common block
!
!   Unified ECMWF and GFS builds                                      
!   Marian Harustak, 12.5.2017                                        
!     - Renamed from verttransform to verttransform_ecmwf
!
!  undocumented modifications by NILU for v10                                *
!                                                                            *
!  Petra Seibert, 2018-06-13:                                                *
!   - fix bug of ticket:140 (find reference position for vertical grid)      *
!   - put back SAVE attribute for INIT, just to be safe                      *
!   - minor changes, most of them just cosmetics                             *
!   for details see changelog.txt                                            *
!                                                                            *
!*****************************************************************************
!                                                                            *
! Variables:                                                                 *
! nx,ny,nz                        field dimensions in x,y and z direction    *
! uu(0:nxmax,0:nymax,nzmax,2)     wind components in x-direction [m/s]       *
! vv(0:nxmax,0:nymax,nzmax,2)     wind components in y-direction [m/s]       *
! ww(0:nxmax,0:nymax,nzmax,2)     wind components in z-direction [deltaeta/s]*
! tt(0:nxmax,0:nymax,nzmax,2)     temperature [K]                            *
! pv(0:nxmax,0:nymax,nzmax,2)     potential voriticity (pvu)                 *
! ps(0:nxmax,0:nymax,2)           surface pressure [Pa]                      *
! clouds(0:nxmax,0:nymax,0:nzmax,2) cloud field for wet deposition           *
!                                                                            *
!*****************************************************************************

  use par_mod
  use com_mod
  use cmapf_mod

  implicit none

  integer :: ix,jy,kz,iz,n,kmin,kl,klp,ix1,jy1,ixp,jyp
  integer :: rain_cloud_above,kz_inv
  real :: f_qvsat,pressure
  real :: rh,lsp,convp
  real :: rhoh(nuvzmax),pinmconv(nzmax)
  real :: ew,pint,tv,tvold,pold,dz1,dz2,dz,ui,vi

!>   for reference profile (PS)  
  real ::  tvoldref, poldref, pintref, psmean, psstd
  integer :: ixyref(2), ixref,jyref
  integer, parameter :: ioldref = 1 ! PS 2018-06-13: set to 0 if you 
!!   want old method of searching reference location for the vertical grid
!!   1 for new method (options for other methods 2,... in the future)

  real :: xlon,ylat,xlonr,dzdx,dzdy
  real :: dzdx1,dzdx2,dzdy1,dzdy2,cosf
  real :: uuaux,vvaux,uupolaux,vvpolaux,ddpol,ffpol,wdummy
  real :: uuh(0:nxmax-1,0:nymax-1,nuvzmax)
  real :: vvh(0:nxmax-1,0:nymax-1,nuvzmax)
  real :: pvh(0:nxmax-1,0:nymax-1,nuvzmax)
  real :: wwh(0:nxmax-1,0:nymax-1,nwzmax)
  real :: wzlev(nwzmax),uvwzlev(0:nxmax-1,0:nymax-1,nzmax)
  real,parameter :: const=r_air/ga

  logical, save :: init = .true. ! PS 2018-06-13: add back save attribute

!> GFS version
  integer :: llev, i



!*************************************************************************
! If verttransform is called the first time, initialize heights of the   *
! z levels in meter. The heights are the heights of model levels, where  *
! u,v,T and qv are given.                                                *
!*************************************************************************

  if (init) then

! Search for a point with high surface pressure (i.e. not above significant topography)
! Then, use this point to construct a reference z profile, to be used at all times
!*****************************************************************************

    if (ioldref .eq. 0) then ! old reference grid point
      do jy=0,nymin1
        do ix=0,nxmin1
          if (ps(ix,jy,1,n).gt.1000.e2) then
            ixref=ix
            jyref=jy
          goto 3
        endif
      end do
    end do
3   continue
!      print*,'oldheights at' ,ixref,jyref,ps(ixref,jyref,1,n)
    else ! new reference grid point
!     PS: the old version fails if the pressure is <=1000 hPa in the whole
!     domain. Let us find a good replacement, not just a quick fix.
!     Search point near to mean pressure after excluding mountains

      psmean = sum( ps(:,:,1,n) ) / (nx*ny)
!      print*,'height: fg psmean',psmean
      psstd = sqrt(sum( (ps(:,:,1,n) - psmean)**2 ) / (nx*ny))

!>    new psmean using only points within $\plusminus\sigma$  
!      psmean = sum( ps(:,:,1,n), abs(ps(:,:,1,n)-psmean) < psstd ) / &
!        count(abs(ps(:,:,1,n)-psmean) < psstd)

!>    new psmean using only points with $p\gt \overbar{p}+\sigma_p$  
!>    (reject mountains, accept valleys)
      psmean = sum( ps(:,:,1,n), ps(:,:,1,n) > psmean - psstd ) / &
        count(ps(:,:,1,n) > psmean - psstd)
!      print*,'height: std, new psmean',psstd,psmean
      ixyref = minloc( abs( ps(:,:,1,n) - psmean ) )
      ixref = ixyref(1)
      jyref = ixyref(2)
!      print*,'newheights at' ,ixref,jyref,ps(ixref,jyref,1,n)
    endif  

    tvoldref=tt2(ixref,jyref,1,n)* &
      ( 1. + 0.378*ew(td2(ixref,jyref,1,n) ) / ps(ixref,jyref,1,n))
    poldref=ps(ixref,jyref,1,n)
    height(1)=0.
    kz=1
!    print*,'height=',kz,height(kz),tvoldref,poldref

    do kz=2,nuvz
      
      pintref = akz(kz) 
      ! Note that for GFS data, the akz variable contains the input level
      ! pressure values. bkz is zero (I removed all terms with bkz that
      ! were erroneously copied from verttransform_ecmwf). [PS, June 2018]
       
      tv = tth(ixref,jyref,kz,n)*(1.+0.608*qvh(ixref,jyref,kz,n))

      if (abs(tv-tvoldref) .gt. 0.2) then
        height(kz)=height(kz-1) + &
          const * log(poldref/pintref) * (tv-tvoldref) / log(tv/tvoldref)
      else
        height(kz) = height(kz-1) + const*log(poldref/pintref)*tv
      endif

      tvoldref=tv
      poldref=pintref
!      print*,'height=',kz,height(kz),tvoldref,poldref
    end do


! Determine highest levels that can be within PBL
!************************************************

    do kz=1,nz
      if (height(kz).gt.hmixmax) then
        nmixz=kz
        goto 9
      endif
    end do
9   continue

! Do not repeat initialization of the Cartesian z grid
!*****************************************************

    init=.false.

  endif ! init block (vertical grid construction)


! Loop over the whole grid
!*************************

  do jy=0,nymin1
    do ix=0,nxmin1

! NCEP version: find first level above ground
      llev = 0
      do i=1,nuvz
        if (ps(ix,jy,1,n).lt.akz(i)) llev=i
      end do
       llev = llev+1
       if (llev.gt.nuvz-2) llev = nuvz-2
!     if (llev.eq.nuvz-2) write(*,*) 'verttransform
!    +WARNING: LLEV eq NUZV-2'
! NCEP version


! compute height of pressure levels above ground
!***********************************************

      tvold=tth(ix,jy,llev,n)*(1.+0.608*qvh(ix,jy,llev,n))
      pold=akz(llev)
      wzlev(llev)=0.
      uvwzlev(ix,jy,llev)=0.
      rhoh(llev)=pold/(r_air*tvold)

      do kz=llev+1,nuvz
        pint=akz(kz)+bkz(kz)*ps(ix,jy,1,n)
        tv=tth(ix,jy,kz,n)*(1.+0.608*qvh(ix,jy,kz,n))
        rhoh(kz)=pint/(r_air*tv)

        if (abs(tv-tvold).gt.0.2) then
          uvwzlev(ix,jy,kz)=uvwzlev(ix,jy,kz-1)+const*log(pold/pint)* &
          (tv-tvold)/log(tv/tvold)
        else
          uvwzlev(ix,jy,kz)=uvwzlev(ix,jy,kz-1)+const*log(pold/pint)*tv
        endif
        wzlev(kz)=uvwzlev(ix,jy,kz)

        tvold=tv
        pold=pint
      end do

! pinmconv=(h2-h1)/(p2-p1)

      pinmconv(llev)=(uvwzlev(ix,jy,llev+1)-uvwzlev(ix,jy,llev))/ &
           ((aknew(llev+1)+bknew(llev+1)*ps(ix,jy,1,n))- &
           (aknew(llev)+bknew(llev)*ps(ix,jy,1,n)))
      do kz=llev+1,nz-1
        pinmconv(kz)=(uvwzlev(ix,jy,kz+1)-uvwzlev(ix,jy,kz-1))/ &
             ((aknew(kz+1)+bknew(kz+1)*ps(ix,jy,1,n))- &
             (aknew(kz-1)+bknew(kz-1)*ps(ix,jy,1,n)))
      end do
      pinmconv(nz)=(uvwzlev(ix,jy,nz)-uvwzlev(ix,jy,nz-1))/ &
           ((aknew(nz)+bknew(nz)*ps(ix,jy,1,n))- &
           (aknew(nz-1)+bknew(nz-1)*ps(ix,jy,1,n)))


! Levels, where u,v,t and q are given
!************************************

      uu(ix,jy,1,n)=uuh(ix,jy,llev)
      vv(ix,jy,1,n)=vvh(ix,jy,llev)
      tt(ix,jy,1,n)=tth(ix,jy,llev,n)
      qv(ix,jy,1,n)=qvh(ix,jy,llev,n)
      pv(ix,jy,1,n)=pvh(ix,jy,llev)
      rho(ix,jy,1,n)=rhoh(llev)
      pplev(ix,jy,1,n)=akz(llev)
      uu(ix,jy,nz,n)=uuh(ix,jy,nuvz)
      vv(ix,jy,nz,n)=vvh(ix,jy,nuvz)
      tt(ix,jy,nz,n)=tth(ix,jy,nuvz,n)
      qv(ix,jy,nz,n)=qvh(ix,jy,nuvz,n)
      pv(ix,jy,nz,n)=pvh(ix,jy,nuvz)
      rho(ix,jy,nz,n)=rhoh(nuvz)
      pplev(ix,jy,nz,n)=akz(nuvz)
      kmin=llev+1
      do iz=2,nz-1
        do kz=kmin,nuvz
          if(height(iz).gt.uvwzlev(ix,jy,nuvz)) then
            uu(ix,jy,iz,n)=uu(ix,jy,nz,n)
            vv(ix,jy,iz,n)=vv(ix,jy,nz,n)
            tt(ix,jy,iz,n)=tt(ix,jy,nz,n)
            qv(ix,jy,iz,n)=qv(ix,jy,nz,n)
            pv(ix,jy,iz,n)=pv(ix,jy,nz,n)
            rho(ix,jy,iz,n)=rho(ix,jy,nz,n)
            pplev(ix,jy,iz,n)=pplev(ix,jy,nz,n)
            goto 30
          endif
          if ((height(iz).gt.uvwzlev(ix,jy,kz-1)).and. &
          (height(iz).le.uvwzlev(ix,jy,kz))) then
            dz1=height(iz)-uvwzlev(ix,jy,kz-1)
            dz2=uvwzlev(ix,jy,kz)-height(iz)
            dz=dz1+dz2
            uu(ix,jy,iz,n)=(uuh(ix,jy,kz-1)*dz2+uuh(ix,jy,kz)*dz1)/dz
            vv(ix,jy,iz,n)=(vvh(ix,jy,kz-1)*dz2+vvh(ix,jy,kz)*dz1)/dz
            tt(ix,jy,iz,n)=(tth(ix,jy,kz-1,n)*dz2 &
            +tth(ix,jy,kz,n)*dz1)/dz
            qv(ix,jy,iz,n)=(qvh(ix,jy,kz-1,n)*dz2 &
            +qvh(ix,jy,kz,n)*dz1)/dz
            pv(ix,jy,iz,n)=(pvh(ix,jy,kz-1)*dz2+pvh(ix,jy,kz)*dz1)/dz
            rho(ix,jy,iz,n)=(rhoh(kz-1)*dz2+rhoh(kz)*dz1)/dz
            pplev(ix,jy,iz,n)=(akz(kz-1)*dz2+akz(kz)*dz1)/dz
          endif
        end do
30      continue
      end do


! Levels, where w is given
!*************************

      ww(ix,jy,1,n)=wwh(ix,jy,llev)*pinmconv(llev)
      ww(ix,jy,nz,n)=wwh(ix,jy,nwz)*pinmconv(nz)
      kmin=llev+1
      do iz=2,nz
        do kz=kmin,nwz
          if ((height(iz).gt.wzlev(kz-1)).and. &
          (height(iz).le.wzlev(kz))) then
            dz1=height(iz)-wzlev(kz-1)
            dz2=wzlev(kz)-height(iz)
            dz=dz1+dz2
            ww(ix,jy,iz,n)=(wwh(ix,jy,kz-1)*pinmconv(kz-1)*dz2 &
            +wwh(ix,jy,kz)*pinmconv(kz)*dz1)/dz
          endif
        end do
      end do


! Compute density gradients at intermediate levels
!*************************************************

      drhodz(ix,jy,1,n)=(rho(ix,jy,2,n)-rho(ix,jy,1,n))/ &
           (height(2)-height(1))
      do kz=2,nz-1
        drhodz(ix,jy,kz,n)=(rho(ix,jy,kz+1,n)-rho(ix,jy,kz-1,n))/ &
        (height(kz+1)-height(kz-1))
      end do
      drhodz(ix,jy,nz,n)=drhodz(ix,jy,nz-1,n)

    end do
  end do


!****************************************************************
! Compute slope of eta levels in windward direction and resulting
! vertical wind correction
!****************************************************************

  do jy=1,ny-2
    cosf=cos((real(jy)*dy+ylat0)*pi180)
    do ix=1,nx-2

! NCEP version: find first level above ground
      llev = 0
      do i=1,nuvz
       if (ps(ix,jy,1,n).lt.akz(i)) llev=i
      end do
       llev = llev+1
       if (llev.gt.nuvz-2) llev = nuvz-2
!     if (llev.eq.nuvz-2) write(*,*) 'verttransform
!    +WARNING: LLEV eq NUZV-2'
! NCEP version

      kmin=llev+1
      do iz=2,nz-1

        ui=uu(ix,jy,iz,n)*dxconst/cosf
        vi=vv(ix,jy,iz,n)*dyconst

        do kz=kmin,nz
          if ((height(iz).gt.uvwzlev(ix,jy,kz-1)).and. &
          (height(iz).le.uvwzlev(ix,jy,kz))) then
            dz1=height(iz)-uvwzlev(ix,jy,kz-1)
            dz2=uvwzlev(ix,jy,kz)-height(iz)
            dz=dz1+dz2
            kl=kz-1
            klp=kz
            goto 47
          endif
        end do

47      ix1=ix-1
        jy1=jy-1
        ixp=ix+1
        jyp=jy+1

        dzdx1=(uvwzlev(ixp,jy,kl)-uvwzlev(ix1,jy,kl))/2.
        dzdx2=(uvwzlev(ixp,jy,klp)-uvwzlev(ix1,jy,klp))/2.
        dzdx=(dzdx1*dz2+dzdx2*dz1)/dz

        dzdy1=(uvwzlev(ix,jyp,kl)-uvwzlev(ix,jy1,kl))/2.
        dzdy2=(uvwzlev(ix,jyp,klp)-uvwzlev(ix,jy1,klp))/2.
        dzdy=(dzdy1*dz2+dzdy2*dz1)/dz

        ww(ix,jy,iz,n)=ww(ix,jy,iz,n)+(dzdx*ui+dzdy*vi)

      end do

    end do
  end do


! If north pole is in the domain, calculate wind velocities in polar
! stereographic coordinates
!*******************************************************************

  if (nglobal) then
    do jy=int(switchnorthg)-2,nymin1
      ylat=ylat0+real(jy)*dy
      do ix=0,nxmin1
        xlon=xlon0+real(ix)*dx
        do iz=1,nz
          call cc2gll(northpolemap,ylat,xlon,uu(ix,jy,iz,n), &
               vv(ix,jy,iz,n),uupol(ix,jy,iz,n), &
               vvpol(ix,jy,iz,n))
        end do
      end do
    end do


    do iz=1,nz

! CALCULATE FFPOL, DDPOL FOR CENTRAL GRID POINT
      xlon=xlon0+real(nx/2-1)*dx
      xlonr=xlon*pi/180.
      ffpol=sqrt(uu(nx/2-1,nymin1,iz,n)**2+vv(nx/2-1,nymin1,iz,n)**2)
      if (vv(nx/2-1,nymin1,iz,n).lt.0.) then
        ddpol=atan(uu(nx/2-1,nymin1,iz,n)/vv(nx/2-1,nymin1,iz,n))-xlonr
      elseif (vv(nx/2-1,nymin1,iz,n).gt.0.) then
        ddpol=pi+atan(uu(nx/2-1,nymin1,iz,n)/ &
        vv(nx/2-1,nymin1,iz,n))-xlonr
      else
        ddpol=pi/2-xlonr
      endif
      if(ddpol.lt.0.) ddpol=2.0*pi+ddpol
      if(ddpol.gt.2.0*pi) ddpol=ddpol-2.0*pi

! CALCULATE U,V FOR 180 DEG, TRANSFORM TO POLAR STEREOGRAPHIC GRID
      xlon=180.0
      xlonr=xlon*pi/180.
      ylat=90.0
      uuaux=-ffpol*sin(xlonr+ddpol)
      vvaux=-ffpol*cos(xlonr+ddpol)
      call cc2gll(northpolemap,ylat,xlon,uuaux,vvaux,uupolaux,vvpolaux)
      jy=nymin1
      do ix=0,nxmin1
        uupol(ix,jy,iz,n)=uupolaux
        vvpol(ix,jy,iz,n)=vvpolaux
      end do
    end do


! Fix: Set W at pole to the zonally averaged W of the next equator-
! ward parallel of latitude

    do iz=1,nz
      wdummy=0.
      jy=ny-2
      do ix=0,nxmin1
        wdummy=wdummy+ww(ix,jy,iz,n)
      end do
      wdummy=wdummy/real(nx)
      jy=nymin1
      do ix=0,nxmin1
        ww(ix,jy,iz,n)=wdummy
      end do
    end do

  endif


! If south pole is in the domain, calculate wind velocities in polar
! stereographic coordinates
!*******************************************************************

  if (sglobal) then
    do jy=0,int(switchsouthg)+3
      ylat=ylat0+real(jy)*dy
      do ix=0,nxmin1
        xlon=xlon0+real(ix)*dx
        do iz=1,nz
          call cc2gll(southpolemap,ylat,xlon,uu(ix,jy,iz,n), &
          vv(ix,jy,iz,n),uupol(ix,jy,iz,n),vvpol(ix,jy,iz,n))
        end do
      end do
    end do

    do iz=1,nz

! CALCULATE FFPOL, DDPOL FOR CENTRAL GRID POINT
      xlon=xlon0+real(nx/2-1)*dx
      xlonr=xlon*pi/180.
      ffpol=sqrt(uu(nx/2-1,0,iz,n)**2+vv(nx/2-1,0,iz,n)**2)
      if(vv(nx/2-1,0,iz,n).lt.0.) then
        ddpol=atan(uu(nx/2-1,0,iz,n)/vv(nx/2-1,0,iz,n))+xlonr
      elseif (vv(nx/2-1,0,iz,n).gt.0.) then
        ddpol=pi+atan(uu(nx/2-1,0,iz,n)/vv(nx/2-1,0,iz,n))-xlonr
      else
        ddpol=pi/2-xlonr
      endif
      if(ddpol.lt.0.) ddpol=2.0*pi+ddpol
      if(ddpol.gt.2.0*pi) ddpol=ddpol-2.0*pi

! CALCULATE U,V FOR 180 DEG, TRANSFORM TO POLAR STEREOGRAPHIC GRID
      xlon=180.0
      xlonr=xlon*pi/180.
      ylat=-90.0
      uuaux=+ffpol*sin(xlonr-ddpol)
      vvaux=-ffpol*cos(xlonr-ddpol)
      call cc2gll(northpolemap,ylat,xlon,uuaux,vvaux,uupolaux,vvpolaux)

      jy=0
      do ix=0,nxmin1
        uupol(ix,jy,iz,n)=uupolaux
        vvpol(ix,jy,iz,n)=vvpolaux
      end do
    end do


! Fix: Set W at pole to the zonally averaged W of the next equator-
! ward parallel of latitude

    do iz=1,nz
      wdummy=0.
      jy=1
      do ix=0,nxmin1
        wdummy=wdummy+ww(ix,jy,iz,n)
      end do
      wdummy=wdummy/real(nx)
      jy=0
      do ix=0,nxmin1
        ww(ix,jy,iz,n)=wdummy
      end do
    end do
  endif


!   write (*,*) 'initializing clouds, n:',n,nymin1,nxmin1,nz
!   create a cloud and rainout/washout field, clouds occur where rh>80%
!   total cloudheight is stored at level 0
  do jy=0,nymin1
    do ix=0,nxmin1
      rain_cloud_above=0
      lsp=lsprec(ix,jy,1,n)
      convp=convprec(ix,jy,1,n)
      cloudsh(ix,jy,n)=0
      do kz_inv=1,nz-1
         kz=nz-kz_inv+1
         pressure=rho(ix,jy,kz,n)*r_air*tt(ix,jy,kz,n)
         rh=qv(ix,jy,kz,n)/f_qvsat(pressure,tt(ix,jy,kz,n))
         clouds(ix,jy,kz,n)=0
         if (rh.gt.0.8) then ! in cloud
           if ((lsp.gt.0.01).or.(convp.gt.0.01)) then ! cloud and precipitation
              rain_cloud_above=1
              cloudsh(ix,jy,n)=cloudsh(ix,jy,n)+height(kz)-height(kz-1)
              if (lsp.ge.convp) then
                 clouds(ix,jy,kz,n)=3 ! lsp dominated rainout
              else
                 clouds(ix,jy,kz,n)=2 ! convp dominated rainout
              endif
           else ! no precipitation
             clouds(ix,jy,kz,n)=1 ! cloud
           endif
         else ! no cloud
           if (rain_cloud_above.eq.1) then ! scavenging
             if (lsp.ge.convp) then
               clouds(ix,jy,kz,n)=5 ! lsp dominated washout
             else
               clouds(ix,jy,kz,n)=4 ! convp dominated washout
             endif
           endif
         endif
      end do
    end do
  end do


end subroutine verttransform_gfs
